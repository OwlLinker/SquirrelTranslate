#include "query_translation_service.h"

#include "public_translation_providers.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdlib>
#include <cstring>
#include <deque>
#include <fstream>
#include <map>
#include <mutex>
#include <set>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace {

constexpr size_t kCacheLimit = 400;
constexpr size_t kQueueLimit = 32;
constexpr size_t kWorkerCount = 2;
constexpr auto kQueryDebounce = std::chrono::milliseconds(300);
constexpr auto kFailureCacheLifetime = std::chrono::seconds(5);

struct ProviderSettings {
  bool enabled = false;
  std::string endpoint;
  std::string api_key;
};

struct Settings {
  std::vector<std::string> order{"mac_dictionary", "google", "bing", "deepl"};
  std::map<std::string, ProviderSettings> providers;

  Settings() {
    providers["mac_dictionary"].enabled = true;
    providers["google"].endpoint =
        "https://translate.google.com/translate_a/single";
    providers["bing"].endpoint = "https://cn.bing.com/translator";
    providers["deepl"].endpoint = "https://api-free.deepl.com/v2/translate";
  }
};

std::string Trim(std::string value) {
  const size_t first = value.find_first_not_of(" \t\r\n");
  if (first == std::string::npos) return {};
  const size_t last = value.find_last_not_of(" \t\r\n");
  return value.substr(first, last - first + 1);
}

std::string Unquote(std::string value) {
  value = Trim(std::move(value));
  if (value.size() >= 2 &&
      ((value.front() == '"' && value.back() == '"') ||
       (value.front() == '\'' && value.back() == '\''))) {
    value = value.substr(1, value.size() - 2);
  }
  return value;
}

std::string StripYamlComment(const std::string& line) {
  char quote = 0;
  for (size_t index = 0; index < line.size(); ++index) {
    const char value = line[index];
    if ((value == '"' || value == '\'') &&
        (index == 0 || line[index - 1] != '\\')) {
      if (quote == value) quote = 0;
      else if (quote == 0) quote = value;
    } else if (value == '#' && quote == 0 &&
               (index == 0 || line[index - 1] == ' ' ||
                line[index - 1] == '\t')) {
      return line.substr(0, index);
    }
  }
  return line;
}

bool IsPublicProvider(const std::string& name) {
  return name == "mac_dictionary" || name == "google" ||
         name == "bing" || name == "deepl";
}

Settings LoadSettings() {
  Settings result;
  const char* home = std::getenv("HOME");
  if (!home || !*home) return result;
  std::ifstream file(std::string(home) +
                     "/Library/Rime/translation.providers.yaml");
  if (!file) return result;

  enum class Section { kNone, kOrder, kProviders };
  Section section = Section::kNone;
  std::string current_provider;
  std::vector<std::string> configured_order;
  std::string raw;
  while (std::getline(file, raw)) {
    const std::string line = StripYamlComment(raw);
    const std::string trimmed = Trim(line);
    if (trimmed.empty()) continue;
    if (trimmed == "provider_order:") {
      section = Section::kOrder;
      current_provider.clear();
      continue;
    }
    if (trimmed == "providers:") {
      section = Section::kProviders;
      current_provider.clear();
      continue;
    }
    if (section == Section::kOrder && trimmed.rfind("- ", 0) == 0) {
      const std::string name = Unquote(trimmed.substr(2));
      if (IsPublicProvider(name)) configured_order.push_back(name);
      continue;
    }
    if (section != Section::kProviders) continue;

    const size_t indentation = line.find_first_not_of(" \t");
    const size_t colon = trimmed.find(':');
    if (colon == std::string::npos) continue;
    const std::string key = Trim(trimmed.substr(0, colon));
    const std::string value = Unquote(trimmed.substr(colon + 1));
    if (indentation == 2) {
      current_provider = IsPublicProvider(key) ? key : std::string();
      continue;
    }
    if (indentation < 4 || current_provider.empty()) continue;
    ProviderSettings& provider = result.providers[current_provider];
    if (key == "enabled") provider.enabled = value == "true";
    else if (key == "endpoint") provider.endpoint = value;
    else if (key == "api_key") provider.api_key = value;
  }
  if (!configured_order.empty()) result.order = std::move(configured_order);
  return result;
}

std::string MakeKey(const std::string& target, const std::string& word) {
  return target + '\0' + word;
}

struct Job {
  std::string word;
  std::string target;
  uint64_t generation = 0;
  SquirrelQueryTranslationCallback callback = nullptr;
  void* context = nullptr;
  std::chrono::steady_clock::time_point queued_at =
      std::chrono::steady_clock::now();
};

class QueryTranslationService {
 public:
  QueryTranslationService() : settings_(LoadSettings()) {}

  ~QueryTranslationService() { Shutdown(); }

  void SetGeneration(uint64_t generation) {
    generation_.store(generation);
    std::lock_guard<std::mutex> lock(mutex_);
    queue_.clear();
    queued_keys_.clear();
    wake_.notify_all();
  }

  void Request(const char* raw_word, const char* raw_target,
               uint64_t generation,
               SquirrelQueryTranslationCallback callback, void* context) {
    if (!raw_word || !raw_target || !callback || raw_word[0] == '\0' ||
        generation == 0 || generation != generation_.load()) return;
    Job job{raw_word, raw_target, generation, callback, context};
    const std::string key = MakeKey(job.target, job.word);
    bool has_cached_result = false;
    CacheEntry cached_result;
    {
      std::lock_guard<std::mutex> lock(mutex_);
      auto cached = cache_.find(key);
      if (cached != cache_.end()) {
        if (!cached->second.translation.empty()) {
          cached_result = cached->second;
          has_cached_result = true;
        } else if (std::chrono::steady_clock::now() -
                       cached->second.saved_at < kFailureCacheLifetime) {
          return;
        } else {
          cache_.erase(cached);
          cache_order_.erase(std::remove(cache_order_.begin(),
                                         cache_order_.end(), key),
                             cache_order_.end());
        }
      }
      if (!has_cached_result) {
        const std::string generation_key = std::to_string(generation) + key;
        if (queued_keys_.find(generation_key) != queued_keys_.end() ||
            in_flight_keys_.find(generation_key) != in_flight_keys_.end())
          return;
        if (workers_.empty() && !stopping_.load()) {
          for (size_t index = 0; index < kWorkerCount; ++index)
            workers_.emplace_back([this] { Work(); });
        }
        if (queue_.size() >= kQueueLimit) {
          queued_keys_.erase(std::to_string(queue_.front().generation) +
                             MakeKey(queue_.front().target,
                                     queue_.front().word));
          queue_.pop_front();
        }
        queued_keys_.insert(generation_key);
        queue_.push_back(std::move(job));
      }
    }
    if (has_cached_result) {
      callback(generation, raw_word, raw_target, cached_result.translation.c_str(),
               cached_result.phonetic.c_str(), context);
      return;
    }
    wake_.notify_one();
  }

  void Shutdown() {
    if (stopping_.exchange(true)) return;
    generation_.fetch_add(1);
    wake_.notify_all();
    for (std::thread& worker : workers_)
      if (worker.joinable()) worker.join();
    workers_.clear();
  }

 private:
  struct CacheEntry {
    std::string translation;
    std::string phonetic;
    std::chrono::steady_clock::time_point saved_at =
        std::chrono::steady_clock::now();
  };

  std::pair<std::string, std::string> Translate(const Job& job) {
    if (job.target == "tool-keyword") {
      if (!SquirrelQueryKeywordLabel(job.word.c_str())) return {};
      const std::string phonetic = job.word == "conv" || job.word == "ip" ?
          std::string() :
          squirrel_translate_public::FetchMacDictionaryPhonetic(job.word);
      return {job.word, phonetic};
    }
    squirrel_translate_public::Request request{
        job.word, job.target, &generation_, job.generation};
    const auto local = settings_.providers.find("mac_dictionary");
    if (local != settings_.providers.end() && local->second.enabled) {
      squirrel_translate_public::ProviderConfig config{
          local->second.endpoint, local->second.api_key};
      std::string translation = squirrel_translate_public::Fetch(
          "mac_dictionary", request, config);
      if (!translation.empty()) {
        const std::string phonetic = job.target == "en" ?
            squirrel_translate_public::FetchMacDictionaryPhonetic(translation) :
            std::string();
        return {translation, phonetic};
      }
    }
    for (const std::string& name : settings_.order) {
      if (generation_.load() != job.generation) break;
      if (name == "mac_dictionary") continue;
      const auto found = settings_.providers.find(name);
      if (found == settings_.providers.end() || !found->second.enabled) continue;
      squirrel_translate_public::ProviderConfig config{
          found->second.endpoint, found->second.api_key};
      std::string translation = squirrel_translate_public::Fetch(
          name, request, config);
      if (!translation.empty()) {
        const std::string phonetic = job.target == "en" ?
            squirrel_translate_public::FetchMacDictionaryPhonetic(translation) :
            std::string();
        return {translation, phonetic};
      }
    }
    return {};
  }

  void Work() {
    while (true) {
      Job job;
      {
        std::unique_lock<std::mutex> lock(mutex_);
        wake_.wait(lock, [this] { return stopping_.load() || !queue_.empty(); });
        if (stopping_.load()) return;
        job = std::move(queue_.front());
        queue_.pop_front();
        const std::string request_key = std::to_string(job.generation) +
            MakeKey(job.target, job.word);
        queued_keys_.erase(request_key);
        in_flight_keys_.insert(request_key);
      }
      const std::string request_key = std::to_string(job.generation) +
          MakeKey(job.target, job.word);
      if (generation_.load() != job.generation) {
        std::lock_guard<std::mutex> lock(mutex_);
        in_flight_keys_.erase(request_key);
        continue;
      }
      {
        std::unique_lock<std::mutex> lock(mutex_);
        const auto deadline = job.queued_at + kQueryDebounce;
        while (!stopping_.load() && generation_.load() == job.generation &&
               std::chrono::steady_clock::now() < deadline) {
          wake_.wait_until(lock, deadline);
        }
      }
      if (stopping_.load() || generation_.load() != job.generation) {
        std::lock_guard<std::mutex> lock(mutex_);
        in_flight_keys_.erase(request_key);
        continue;
      }
      auto result = Translate(job);
      {
        std::lock_guard<std::mutex> lock(mutex_);
        in_flight_keys_.erase(request_key);
        if (generation_.load() == job.generation) {
          const std::string cache_key = MakeKey(job.target, job.word);
          if (cache_.find(cache_key) == cache_.end())
            cache_order_.push_back(cache_key);
          cache_[cache_key] = {result.first, result.second,
                               std::chrono::steady_clock::now()};
          while (cache_order_.size() > kCacheLimit) {
            cache_.erase(cache_order_.front());
            cache_order_.pop_front();
          }
        }
      }
      if (generation_.load() == job.generation && job.callback &&
          !result.first.empty())
        job.callback(job.generation, job.word.c_str(), job.target.c_str(),
                     result.first.c_str(), result.second.c_str(), job.context);
    }
  }

  Settings settings_;
  std::atomic<uint64_t> generation_{0};
  std::atomic<bool> stopping_{false};
  std::mutex mutex_;
  std::condition_variable wake_;
  std::deque<Job> queue_;
  std::set<std::string> queued_keys_;
  std::set<std::string> in_flight_keys_;
  std::map<std::string, CacheEntry> cache_;
  std::deque<std::string> cache_order_;
  std::vector<std::thread> workers_;
};

QueryTranslationService& Service() {
  static QueryTranslationService service;
  return service;
}

}  // namespace

extern "C" const char* SquirrelQueryKeywordLabel(const char* keyword) {
  if (!keyword) return nullptr;
  struct Entry { const char* keyword; const char* label; };
  static constexpr Entry entries[] = {
      {"color", "颜色"}, {"time", "时间"}, {"date", "日期"},
      {"conv", "换算"}, {"ip", "网络协议"}, {"phone", "电话"}};
  for (const Entry& entry : entries)
    if (std::strcmp(keyword, entry.keyword) == 0) return entry.label;
  return nullptr;
}

extern "C" void SquirrelQueryTranslationSetGeneration(uint64_t generation) {
  Service().SetGeneration(generation);
}

extern "C" void SquirrelQueryTranslationRequest(
    const char* word, const char* target, uint64_t generation,
    SquirrelQueryTranslationCallback callback, void* context) {
  Service().Request(word, target, generation, callback, context);
}

extern "C" void SquirrelQueryTranslationShutdown(void) {
  Service().Shutdown();
}
