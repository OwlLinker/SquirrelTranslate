#include "../src/query_translation_service.h"
#include "../src/public_translation_providers.h"

#include <cassert>
#include <chrono>
#include <condition_variable>
#include <map>
#include <mutex>
#include <string>

struct Results {
  std::mutex mutex;
  std::condition_variable ready;
  std::map<std::string, std::pair<std::string, std::string>> values;
};

static void OnTranslation(uint64_t, const char* word, const char*,
                          const char* translation, const char* phonetic,
                          void* context) {
  auto* results = static_cast<Results*>(context);
  {
    std::lock_guard<std::mutex> lock(results->mutex);
    results->values[word] = {translation, phonetic};
  }
  results->ready.notify_one();
}

int main() {
  Results results;
  assert(std::string(SquirrelQueryKeywordLabel("color")) == "颜色");
  assert(std::string(SquirrelQueryKeywordLabel("time")) == "时间");
  assert(std::string(SquirrelQueryKeywordLabel("date")) == "日期");
  assert(std::string(SquirrelQueryKeywordLabel("conv")) == "换算");
  assert(std::string(SquirrelQueryKeywordLabel("ip")) == "网络协议");
  assert(std::string(SquirrelQueryKeywordLabel("phone")) == "电话");
  assert(SquirrelQueryKeywordLabel("unknown") == nullptr);
  SquirrelQueryTranslationSetGeneration(1);
  SquirrelQueryTranslationRequest("color", "tool-keyword", 1,
                                  OnTranslation, &results);
  SquirrelQueryTranslationRequest("date", "tool-keyword", 1,
                                  OnTranslation, &results);
  {
    std::unique_lock<std::mutex> lock(results.mutex);
    assert(results.ready.wait_for(lock, std::chrono::seconds(5), [&] {
      return results.values.size() == 2;
    }));
    assert(results.values.at("color").first == "color");
    assert(results.values.at("date").first == "date");
    assert(results.values.at("color").second ==
           squirrel_translate_public::FetchMacDictionaryPhonetic("color"));
    assert(results.values.at("date").second ==
           squirrel_translate_public::FetchMacDictionaryPhonetic("date"));
  }
  SquirrelQueryTranslationShutdown();
}
