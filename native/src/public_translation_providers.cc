#include "public_translation_providers.h"
#include "json_string.h"

#include <CoreServices/CoreServices.h>
#include <cerrno>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <unistd.h>

#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <vector>

extern char** environ;

namespace squirrel_translate_public {
namespace {

constexpr char kCurlPath[] = "/usr/bin/curl";
constexpr size_t kOutputLimit = 128 * 1024;
constexpr size_t kBingPageLimit = 1024 * 1024;

bool IsCancelled(const Request& request) {
  return request.generation_source != nullptr && request.generation != 0 &&
         request.generation_source->load() != request.generation;
}

std::string Clean(std::string value) {
  for (char& character : value) {
    if (character == '\r' || character == '\n' || character == '\t') {
      character = ' ';
    }
  }
  const size_t begin = value.find_first_not_of(' ');
  const size_t end = value.find_last_not_of(' ');
  if (begin == std::string::npos) return {};
  return value.substr(begin, end - begin + 1);
}

bool IsEnglishWord(const std::string& value) {
  if (value.empty() || value.size() > 64) return false;
  bool has_letter = false;
  for (unsigned char character : value) {
    if ((character >= 'A' && character <= 'Z') ||
        (character >= 'a' && character <= 'z')) {
      has_letter = true;
      continue;
    }
    if (character == '-' || character == '\'' || character == '.' ||
        character == ' ') {
      continue;
    }
    return false;
  }
  return has_letter;
}

bool ParseStringAt(const std::string& json, size_t start, std::string* value,
                   size_t* end_position) {
  return squirrel_translate_json::ParseStringAt(json, start, value,
                                                 end_position);
}

std::string JsonField(const std::string& json, const std::string& field) {
  const std::string marker = "\"" + field + "\"";
  const size_t marker_position = json.find(marker);
  if (marker_position == std::string::npos) return {};
  size_t value_position = json.find(':', marker_position + marker.size());
  if (value_position == std::string::npos) return {};
  value_position = json.find_first_not_of(" \t\r\n", value_position + 1);
  if (value_position == std::string::npos) return {};
  std::string value;
  size_t end_position = 0;
  return ParseStringAt(json, value_position, &value, &end_position)
             ? Clean(value)
             : std::string();
}

std::string JsonAllFields(const std::string& json, const std::string& field) {
  const std::string marker = "\"" + field + "\"";
  std::string result;
  size_t search_position = 0;
  while (search_position < json.size()) {
    const size_t marker_position = json.find(marker, search_position);
    if (marker_position == std::string::npos) break;
    size_t value_position = json.find(':', marker_position + marker.size());
    if (value_position == std::string::npos) break;
    value_position = json.find_first_not_of(" \t\r\n", value_position + 1);
    if (value_position == std::string::npos) break;
    std::string value;
    size_t end_position = 0;
    if (ParseStringAt(json, value_position, &value, &end_position)) {
      result += value;
      search_position = end_position;
    } else {
      search_position = marker_position + marker.size();
    }
  }
  return Clean(result);
}

bool RunCommand(const std::vector<std::string>& arguments, std::string* output,
                size_t output_limit, const Request& request) {
  if (arguments.empty()) return false;
  int pipe_fds[2] = {-1, -1};
  if (pipe(pipe_fds) != 0) return false;

  posix_spawn_file_actions_t actions;
  const int init_result = posix_spawn_file_actions_init(&actions);
  if (init_result != 0) {
    close(pipe_fds[0]);
    close(pipe_fds[1]);
    return false;
  }
  int action_result = posix_spawn_file_actions_adddup2(
      &actions, pipe_fds[1], STDOUT_FILENO);
  if (action_result == 0)
    action_result = posix_spawn_file_actions_addclose(&actions, pipe_fds[0]);
  if (action_result == 0)
    action_result = posix_spawn_file_actions_addclose(&actions, pipe_fds[1]);
  if (action_result != 0) {
    posix_spawn_file_actions_destroy(&actions);
    close(pipe_fds[0]);
    close(pipe_fds[1]);
    return false;
  }

  std::vector<char*> argv;
  argv.reserve(arguments.size() + 1);
  for (const std::string& argument : arguments) {
    argv.push_back(const_cast<char*>(argument.c_str()));
  }
  argv.push_back(nullptr);

  pid_t child = 0;
  const int spawn_result = posix_spawn(
      &child, arguments.front().c_str(), &actions, nullptr, argv.data(), environ);
  posix_spawn_file_actions_destroy(&actions);
  close(pipe_fds[1]);
  if (spawn_result != 0) {
    close(pipe_fds[0]);
    return false;
  }

  int flags = fcntl(pipe_fds[0], F_GETFL, 0);
  if (flags >= 0) fcntl(pipe_fds[0], F_SETFL, flags | O_NONBLOCK);
  output->clear();
  char buffer[8192];
  int child_status = 0;
  bool child_finished = false;
  bool pipe_closed = false;
  bool cancelled = false;
  while (!pipe_closed || !child_finished) {
    if (IsCancelled(request)) {
      cancelled = true;
      if (!child_finished) kill(child, SIGTERM);
    }
    struct pollfd descriptor {pipe_fds[0], POLLIN | POLLHUP | POLLERR, 0};
    int ready = poll(&descriptor, 1, 50);
    if (ready < 0 && errno == EINTR) continue;
    if (ready > 0 && (descriptor.revents & (POLLIN | POLLHUP | POLLERR))) {
      for (;;) {
        const ssize_t count = read(pipe_fds[0], buffer, sizeof(buffer));
        if (count > 0) {
          if (output->size() < output_limit) {
            output->append(buffer, static_cast<size_t>(count));
            if (output->size() > output_limit) output->resize(output_limit);
          }
        } else if (count == 0 ||
                   (count < 0 && errno != EAGAIN && errno != EINTR)) {
          pipe_closed = true;
          break;
        } else {
          break;
        }
      }
    }
    if (!child_finished) {
      const pid_t result = waitpid(child, &child_status, WNOHANG);
      if (result == child || (result < 0 && errno == ECHILD)) {
        child_finished = true;
      }
    }
  }
  close(pipe_fds[0]);
  if (!child_finished) {
    while (waitpid(child, &child_status, 0) < 0 && errno == EINTR) {
    }
  }
  return !cancelled && WIFEXITED(child_status) && WEXITSTATUS(child_status) == 0;
}

std::string CopyCFString(CFStringRef value) {
  if (!value) return {};
  const CFIndex length = CFStringGetLength(value);
  const CFIndex capacity =
      CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
  std::string result(static_cast<size_t>(capacity), '\0');
  if (!CFStringGetCString(value, result.data(), capacity,
                          kCFStringEncodingUTF8)) {
    return {};
  }
  return result.c_str();
}

std::string DictionaryDefinition(const std::string& word,
                                 DCSDictionaryRef dictionary) {
  if (word.empty()) return {};
  CFStringRef text = CFStringCreateWithBytes(
      nullptr, reinterpret_cast<const UInt8*>(word.data()), word.size(),
      kCFStringEncodingUTF8, false);
  if (!text) return {};
  const CFRange range = CFRangeMake(0, CFStringGetLength(text));
  CFStringRef definition = DCSCopyTextDefinition(dictionary, text, range);
  CFRelease(text);
  if (!definition) return {};
  std::string result = CopyCFString(definition);
  CFRelease(definition);
  return result;
}

std::string FetchMacDictionaryWith(const Request& request,
                                   DCSDictionaryRef dictionary) {
  if (request.target != "en" || request.word.empty() ||
      IsEnglishWord(request.word)) {
    return {};
  }
  const std::string definition = DictionaryDefinition(request.word, dictionary);
  if (definition.empty()) return {};
  size_t line_start = 0;
  bool skipped_headword = false;
  while (line_start <= definition.size()) {
    const size_t line_end = definition.find('\n', line_start);
    std::string line = Clean(definition.substr(
        line_start, line_end == std::string::npos ? std::string::npos
                                                   : line_end - line_start));
    if (!line.empty()) {
      if (!skipped_headword) {
        skipped_headword = true;
      } else {
        const size_t marker = line.find("▸");
        if (marker != std::string::npos) line = Clean(line.substr(0, marker));
        if (!line.empty()) return line;
      }
    }
    if (line_end == std::string::npos) break;
    line_start = line_end + 1;
  }
  return {};
}

std::string FetchGoogle(const Request& request, const ProviderConfig& config) {
  const std::string endpoint = config.endpoint.empty()
                                   ? "https://translate.google.com/translate_a/single"
                                   : config.endpoint;
  std::string response;
  const std::string source = request.target == "en" ? "zh-CN" : "en";
  const std::string target = request.target == "en" ? "en" : "zh-CN";
  const std::vector<std::string> arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "-A", "Mozilla/5.0", "--get", endpoint,
      "--data-urlencode", "client=gtx", "--data-urlencode", "sl=" + source,
      "--data-urlencode", "tl=" + target, "--data-urlencode", "dt=t",
      "--data-urlencode", "dj=1", "--data-urlencode", "ie=UTF-8",
      "--data-urlencode", "q=" + request.word};
  return RunCommand(arguments, &response, kOutputLimit, request)
             ? JsonAllFields(response, "trans")
             : std::string();
}

struct BingCredentials {
  std::string ig;
  std::string iid;
  std::string key;
  std::string token;
  time_t expires = 0;
};

bool ParseBingCredentials(const std::string& body,
                          BingCredentials* credentials) {
  size_t position = body.find("IG:\"");
  if (position == std::string::npos) return false;
  position += 4;
  const size_t end = body.find('"', position);
  if (end == std::string::npos) return false;
  credentials->ig = body.substr(position, end - position);

  position = body.find("data-iid=\"");
  if (position == std::string::npos) return false;
  position += 10;
  const size_t iid_end = body.find('"', position);
  if (iid_end == std::string::npos) return false;
  credentials->iid = body.substr(position, iid_end - position);

  position = body.find("params_AbusePreventionHelper");
  if (position == std::string::npos) return false;
  const size_t array_start = body.find('[', position);
  const size_t array_end = body.find(']', array_start);
  if (array_start == std::string::npos || array_end == std::string::npos) {
    return false;
  }

  std::vector<std::string> values;
  position = array_start + 1;
  while (position < array_end && values.size() < 3) {
    position = body.find_first_not_of(" \t\r\n,", position);
    if (position == std::string::npos || position >= array_end) break;
    if (body[position] == '"') {
      std::string value;
      size_t value_end = 0;
      if (!ParseStringAt(body, position, &value, &value_end)) return false;
      values.push_back(value);
      position = value_end;
    } else {
      size_t value_end = body.find_first_of(",]", position);
      if (value_end == std::string::npos || value_end > array_end) {
        value_end = array_end;
      }
      values.push_back(Clean(body.substr(position, value_end - position)));
      position = value_end;
    }
  }
  if (values.size() < 3 || values[0].empty() || values[1].empty()) return false;
  credentials->key = values[0];
  credentials->token = values[1];
  const long long expiry_ms = std::strtoll(values[2].c_str(), nullptr, 10);
  credentials->expires = time(nullptr) + (expiry_ms > 0 ? expiry_ms : 1800000) / 1000 - 60;
  return true;
}

std::string FetchBing(const Request& request, const ProviderConfig& config) {
  const std::string endpoint = config.endpoint.empty()
                                   ? "https://cn.bing.com/translator"
                                   : config.endpoint;
  static BingCredentials cached_credentials;
  static std::mutex credentials_mutex;
  BingCredentials credentials;
  {
    std::lock_guard<std::mutex> lock(credentials_mutex);
    if (cached_credentials.expires <= time(nullptr)) {
      std::string page;
      const std::vector<std::string> arguments = {
          kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
          "--connect-timeout", "2", "-A", "Mozilla/5.0", "--compressed",
          endpoint};
      if (!RunCommand(arguments, &page, kBingPageLimit, request) ||
          !ParseBingCredentials(page, &cached_credentials)) {
        cached_credentials = {};
        return {};
      }
    }
    credentials = cached_credentials;
  }
  const std::string url = "https://cn.bing.com/ttranslatev3?isVertical=1&IG=" +
                          credentials.ig + "&IID=" + credentials.iid;
  std::string response;
  const std::string source = request.target == "en" ? "zh-Hans" : "en";
  const std::string target = request.target == "en" ? "en" : "zh-Hans";
  const std::vector<std::string> arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "-A", "Mozilla/5.0", "-X", "POST", url,
      "-H", "Content-Type: application/x-www-form-urlencoded",
      "-H", "Referer: https://cn.bing.com/translator", "--compressed",
      "--data-urlencode", "fromLang=" + source, "--data-urlencode",
      "to=" + target, "--data-urlencode", "text=" + request.word,
      "--data-urlencode", "token=" + credentials.token, "--data-urlencode",
      "key=" + credentials.key};
  if (!RunCommand(arguments, &response, kOutputLimit, request)) return {};
  std::string translation = JsonField(response, "text");
  if (translation.empty()) {
    std::lock_guard<std::mutex> lock(credentials_mutex);
    if (cached_credentials.token == credentials.token)
      cached_credentials.expires = 0;
  }
  return translation;
}

std::string FetchDeepL(const Request& request, const ProviderConfig& config) {
  if (config.api_key.empty()) return {};
  const std::string endpoint = config.endpoint.empty()
                                   ? "https://api-free.deepl.com/v2/translate"
                                   : config.endpoint;
  std::string response;
  const std::string target = request.target == "zh-CN" ? "ZH" :
                             request.target == "zh-TW" ? "ZH-HANT" :
                             request.target == "en" ? "EN" : request.target;
  const std::vector<std::string> arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "-X", "POST", endpoint,
      "-H", "Authorization: DeepL-Auth-Key " + config.api_key,
      "-H", "Content-Type: application/x-www-form-urlencoded",
      "--data-urlencode", "text=" + request.word,
      "--data-urlencode", "target_lang=" + target};
  if (!RunCommand(arguments, &response, kOutputLimit, request)) return {};
  return JsonField(response, "text");
}

}  // namespace

std::string FetchMacDictionaryDefault(const Request& request) {
  // NULL is the supported Dictionary Services way to query the user's active
  // dictionaries in macOS-defined order.
  return FetchMacDictionaryWith(request, nullptr);
}

std::string FetchMacDictionaryAt(const Request& request,
                                 std::size_t dictionary_index) {
  // The public implementation intentionally supports only the system-default
  // active-dictionary order; it does not enumerate private dictionary handles.
  return dictionary_index == 0 ? FetchMacDictionaryDefault(request)
                               : std::string();
}

std::string FetchMacDictionaryPhonetic(const std::string& english_text) {
  // Bilingual definitions often list alternatives separated by semicolons.
  // The first displayed translation is the one whose pronunciation belongs
  // beside the candidate.
  const std::string first_translation = Clean(
      english_text.substr(0, english_text.find(';')));
  if (!IsEnglishWord(first_translation)) return {};
  std::string result;
  std::string word;
  auto append_word = [&result, &word] {
    if (word.size() < 2 || word.size() > 64) {
      word.clear();
      return;
    }
    const std::string definition = DictionaryDefinition(word, nullptr);
    size_t opening = definition.find('/');
    while (opening != std::string::npos) {
      const size_t closing = definition.find('/', opening + 1);
      if (closing == std::string::npos) break;
      std::string pronunciation = Clean(
          definition.substr(opening + 1, closing - opening - 1));
      const size_t dialect = pronunciation.find('$');
      if (dialect != std::string::npos)
        pronunciation = Clean(pronunciation.substr(0, dialect));
      if (!pronunciation.empty() && pronunciation.size() <= 96 &&
          pronunciation.find(' ') == std::string::npos) {
        if (!result.empty()) result += " ";
        result += pronunciation;
        break;
      }
      opening = definition.find('/', closing + 1);
    }
    word.clear();
  };
  for (unsigned char character : first_translation) {
    if ((character >= 'A' && character <= 'Z') ||
        (character >= 'a' && character <= 'z')) {
      word += static_cast<char>(character);
    } else {
      append_word();
    }
  }
  append_word();
  return result;
}

std::string Fetch(const std::string& provider, const Request& request,
                  const ProviderConfig& config) {
  if (provider == "mac_dictionary") return FetchMacDictionaryDefault(request);
  if (provider == "google") return FetchGoogle(request, config);
  if (provider == "bing") return FetchBing(request, config);
  if (provider == "deepl") return FetchDeepL(request, config);
  return {};
}

}  // namespace squirrel_translate_public
