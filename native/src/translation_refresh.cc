#include <algorithm>
#include <atomic>
#include <cerrno>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <condition_variable>
#include <cstdio>
#include <ctime>
#include <deque>
#include <fstream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

#include <CommonCrypto/CommonDigest.h>
#include <CommonCrypto/CommonCryptor.h>
#include <CoreServices/CoreServices.h>
#include <dispatch/dispatch.h>
#include <fcntl.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <sys/event.h>
#include <sys/stat.h>
#include <sys/wait.h>
#include <spawn.h>
#include <unistd.h>

#include <rime/component.h>
#include <rime/candidate.h>
#include <rime/config.h>
#include <rime/context.h>
#include <rime/engine.h>
#include <rime/key_event.h>
#include <rime/menu.h>
#include <rime/processor.h>
#include <rime/registry.h>
#include <rime_api.h>

extern char** environ;

namespace {

constexpr char kComponentName[] = "translation_refresh_processor";
constexpr char kRefreshProperty[] = "_refresh_ui";
constexpr char kSelectedCandidateProperty[] = "_translation_selected_text";
constexpr char kSelectedCandidateIndexProperty[] =
    "_translation_selected_index";
constexpr char kRefreshSelectionProperty[] =
    "_translation_refresh_selected_text";
constexpr uintptr_t kStopEvent = 1;
constexpr size_t kTranslationQueueLimit = 32;
constexpr size_t kTranslationWorkerCount = 2;
constexpr size_t kCacheLimit = 400;
constexpr size_t kDefaultCommandOutputLimit = 128 * 1024;
constexpr size_t kBingTokenPageOutputLimit = 1024 * 1024;
constexpr char kCurlPath[] = "/usr/bin/curl";
constexpr char kPythonPath[] = "/usr/bin/python3";
constexpr char kDeepLWebScriptPath[] =
    "/Library/Input Methods/Squirrel.app/Contents/Frameworks/rime-plugins/deepl_web_session.py";
constexpr char kCaiyunApiEndpoint[] =
    "https://api.interpreter.caiyunai.com/v1/translator";

struct TranslationRequest {
  std::string word;
  std::string target;
  bool emoji = false;
  bool phonetic_only = false;
  bool speak_only = false;
  std::string phonetic_word;
  bool allow_online_fallback = true;
};

struct CacheEntry {
  std::string target;
  std::string word;
  std::string translation;
  std::string phonetic;
  std::string provider;
};

std::string CleanField(std::string value) {
  for (char& character : value) {
    if (character == '\r' || character == '\n' || character == '\t') {
      character = ' ';
    }
  }
  size_t begin = value.find_first_not_of(" ");
  size_t end = value.find_last_not_of(" ");
  if (begin == std::string::npos) return {};
  return value.substr(begin, end - begin + 1);
}

std::string CacheKey(const std::string& target, const std::string& word) {
  return target + "\0" + word;
}

std::string RequestKey(const TranslationRequest& request) {
  if (request.speak_only) return std::string("speech") + '\0' + request.word;
  if (request.emoji) return std::string("emoji") + '\0' + request.word;
  return CacheKey(request.target, request.word);
}

std::vector<std::string> SplitTabs(const std::string& line) {
  std::vector<std::string> fields;
  size_t start = 0;
  while (start <= line.size()) {
    size_t end = line.find('\t', start);
    fields.push_back(line.substr(start, end == std::string::npos
                                            ? std::string::npos
                                            : end - start));
    if (end == std::string::npos) break;
    start = end + 1;
  }
  return fields;
}

std::string JsonQuote(const std::string& value) {
  std::string result = "\"";
  for (unsigned char character : value) {
    switch (character) {
      case '\\': result += "\\\\"; break;
      case '"': result += "\\\""; break;
      case '\b': result += "\\b"; break;
      case '\f': result += "\\f"; break;
      case '\n': result += "\\n"; break;
      case '\r': result += "\\r"; break;
      case '\t': result += "\\t"; break;
      default:
        if (character < 0x20) {
          char escaped[7] = {};
          snprintf(escaped, sizeof(escaped), "\\u%04x", character);
          result += escaped;
        } else {
          result += static_cast<char>(character);
        }
    }
  }
  result += '"';
  return result;
}

bool ParseJsonStringAt(const std::string& json, size_t start,
                       std::string* value, size_t* end_position) {
  if (start >= json.size() || json[start] != '"') return false;
  std::string result;
  for (size_t index = start + 1; index < json.size(); ++index) {
    unsigned char character = static_cast<unsigned char>(json[index]);
    if (character == '"') {
      *value = result;
      *end_position = index + 1;
      return true;
    }
    if (character != '\\') {
      result += static_cast<char>(character);
      continue;
    }
    if (++index >= json.size()) return false;
    character = static_cast<unsigned char>(json[index]);
    switch (character) {
      case '"': result += '"'; break;
      case '\\': result += '\\'; break;
      case '/': result += '/'; break;
      case 'b': result += '\b'; break;
      case 'f': result += '\f'; break;
      case 'n': result += '\n'; break;
      case 'r': result += '\r'; break;
      case 't': result += '\t'; break;
      case 'u': {
        if (index + 4 >= json.size()) return false;
        unsigned int codepoint = 0;
        for (size_t offset = 1; offset <= 4; ++offset) {
          char digit = json[index + offset];
          codepoint <<= 4;
          if (digit >= '0' && digit <= '9') codepoint += digit - '0';
          else if (digit >= 'a' && digit <= 'f') codepoint += digit - 'a' + 10;
          else if (digit >= 'A' && digit <= 'F') codepoint += digit - 'A' + 10;
          else return false;
        }
        index += 4;
        if (codepoint <= 0x7f) {
          result += static_cast<char>(codepoint);
        } else if (codepoint <= 0x7ff) {
          result += static_cast<char>(0xc0 | (codepoint >> 6));
          result += static_cast<char>(0x80 | (codepoint & 0x3f));
        } else {
          result += static_cast<char>(0xe0 | (codepoint >> 12));
          result += static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f));
          result += static_cast<char>(0x80 | (codepoint & 0x3f));
        }
        break;
      }
      default: return false;
    }
  }
  return false;
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
        character == ' ') continue;
    return false;
  }
  return has_letter;
}

std::string ExtractLocalDictionaryTranslation(const std::string& definition) {
  size_t end = definition.find("▸");
  std::string head = definition.substr(0, end);
  std::string result;
  std::string current;
  for (unsigned char character : head) {
    const bool ascii_word =
        (character >= 'A' && character <= 'Z') ||
        (character >= 'a' && character <= 'z');
    if (ascii_word) {
      current += static_cast<char>(character);
      continue;
    }
    if (current.size() >= 2) result = current;
    current.clear();
  }
  if (current.size() >= 2) result = current;
  return CleanField(result);
}

std::string ExtractLocalDictionaryPhonetic(const std::string& definition) {
  size_t begin = definition.find('/');
  while (begin != std::string::npos) {
    size_t end = definition.find('/', begin + 1);
    if (end == std::string::npos) break;
    std::string value = CleanField(definition.substr(begin + 1, end - begin - 1));
    if (!value.empty() && value.size() <= 64 && value.find('<') == std::string::npos &&
        value.find('>') == std::string::npos && value.find('@') == std::string::npos) {
      return value;
    }
    begin = definition.find('/', end + 1);
  }
  return {};
}

std::string CopyMacDictionaryDefinition(const std::string& word) {
  if (word.empty()) return {};
  CFStringRef text = CFStringCreateWithBytes(
      nullptr, reinterpret_cast<const UInt8*>(word.data()),
      static_cast<CFIndex>(word.size()), kCFStringEncodingUTF8, false);
  if (!text) return {};
  const CFRange full_range = CFRangeMake(0, CFStringGetLength(text));
  CFStringRef definition = DCSCopyTextDefinition(nullptr, text, full_range);
  CFRelease(text);
  if (!definition) return {};

  const CFIndex length = CFStringGetLength(definition);
  const CFIndex capacity =
      CFStringGetMaximumSizeForEncoding(length, kCFStringEncodingUTF8) + 1;
  std::string utf8(static_cast<size_t>(capacity), '\0');
  std::string result;
  if (CFStringGetCString(definition, utf8.data(), capacity,
                         kCFStringEncodingUTF8)) {
    result = utf8.c_str();
  }
  CFRelease(definition);
  return result;
}

std::string FetchMacDictionary(const TranslationRequest& request) {
  if (request.target != "en" || request.word.empty() ||
      IsEnglishWord(request.word)) {
    return {};
  }
  const std::string definition = CopyMacDictionaryDefinition(request.word);
  if (definition.empty()) return {};
  return ExtractLocalDictionaryTranslation(definition);
}

std::string FetchMacDictionaryPhonetic(const std::string& word) {
  if (!IsEnglishWord(word)) return {};
  return ExtractLocalDictionaryPhonetic(CopyMacDictionaryDefinition(word));
}

std::string ParseJsonField(const std::string& json, const std::string& field) {
  std::string marker = "\"" + field + "\"";
  size_t marker_position = json.find(marker);
  if (marker_position == std::string::npos) return {};
  size_t value_position = json.find(':', marker_position + marker.size());
  if (value_position == std::string::npos) return {};
  value_position = json.find_first_not_of(" \t\r\n", value_position + 1);
  if (value_position == std::string::npos) return {};
  std::string value;
  size_t end_position = 0;
  return ParseJsonStringAt(json, value_position, &value, &end_position)
             ? CleanField(value)
             : std::string();
}

long long ParseJsonIntegerField(const std::string& json,
                                const std::string& field) {
  std::string marker = "\"" + field + "\"";
  size_t marker_position = json.find(marker);
  if (marker_position == std::string::npos) return 0;
  size_t value_position = json.find(':', marker_position + marker.size());
  if (value_position == std::string::npos) return 0;
  value_position = json.find_first_not_of(" \t\r\n", value_position + 1);
  if (value_position == std::string::npos) return 0;
  return std::strtoll(json.c_str() + value_position, nullptr, 10);
}

std::string ParseJsonAllStringFields(const std::string& json,
                                     const std::string& field) {
  std::string marker = "\"" + field + "\"";
  std::string result;
  size_t search_position = 0;
  while (search_position < json.size()) {
    size_t marker_position = json.find(marker, search_position);
    if (marker_position == std::string::npos) break;
    size_t value_position = json.find(':', marker_position + marker.size());
    if (value_position == std::string::npos) break;
    value_position = json.find_first_not_of(" \t\r\n", value_position + 1);
    if (value_position == std::string::npos) break;
    std::string value;
    size_t end_position = 0;
    if (ParseJsonStringAt(json, value_position, &value, &end_position)) {
      result += value;
      search_position = end_position;
    } else {
      search_position = marker_position + marker.size();
    }
  }
  return CleanField(result);
}

std::string ParseJsonFirstArrayString(const std::string& json,
                                      const std::string& field) {
  std::string marker = "\"" + field + "\"";
  size_t marker_position = json.find(marker);
  if (marker_position == std::string::npos) return {};
  size_t value_position = json.find(':', marker_position + marker.size());
  if (value_position == std::string::npos) return {};
  value_position = json.find('[', value_position + 1);
  if (value_position == std::string::npos) return {};
  value_position = json.find_first_not_of(" \t\r\n", value_position + 1);
  if (value_position == std::string::npos) return {};
  value_position = json.find('"', value_position);
  if (value_position == std::string::npos) return {};
  std::string value;
  size_t end_position = 0;
  return ParseJsonStringAt(json, value_position, &value, &end_position)
             ? CleanField(value)
             : std::string();
}

bool RunCommand(const std::vector<std::string>& arguments, std::string* output,
                size_t output_limit = kDefaultCommandOutputLimit) {
  int pipe_fds[2] = {-1, -1};
  if (pipe(pipe_fds) != 0) return false;

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, pipe_fds[1], STDOUT_FILENO);
  posix_spawn_file_actions_addclose(&actions, pipe_fds[0]);
  posix_spawn_file_actions_addclose(&actions, pipe_fds[1]);

  std::vector<char*> argv;
  argv.reserve(arguments.size() + 1);
  for (const std::string& argument : arguments) {
    argv.push_back(const_cast<char*>(argument.c_str()));
  }
  argv.push_back(nullptr);

  pid_t child = 0;
  int spawn_result = posix_spawn(&child, arguments.front().c_str(), &actions,
                                 nullptr, argv.data(), environ);
  posix_spawn_file_actions_destroy(&actions);
  close(pipe_fds[1]);
  if (spawn_result != 0) {
    close(pipe_fds[0]);
    return false;
  }

  output->clear();
  char buffer[8192];
  ssize_t count = 0;
  while ((count = read(pipe_fds[0], buffer, sizeof(buffer))) > 0) {
    if (output->size() < output_limit) {
      output->append(buffer, static_cast<size_t>(count));
      if (output->size() > output_limit) output->resize(output_limit);
    }
  }
  close(pipe_fds[0]);

  int child_status = 0;
  waitpid(child, &child_status, 0);
  return WIFEXITED(child_status) && WEXITSTATUS(child_status) == 0;
}

struct ProviderConfig {
  bool enabled = false;
  std::string web_url;
  std::string endpoint;
  std::string api_endpoint;
  std::string api_key;
  std::string token;
  std::string region;
  std::string app_key;
  std::string app_secret;
};

struct ProviderSettings {
  std::vector<std::string> order;
  std::map<std::string, ProviderConfig> providers;
};

bool ReadConfigString(rime::Config* config, const std::string& path,
                      std::string* value) {
  return config && config->GetString(path, value);
}

ProviderSettings LoadProviderSettings(const std::string& path) {
  ProviderSettings settings;
  rime::Config config;
  if (!config.LoadFromFile(rime::path(path))) {
    settings.order = {"mac_dictionary", "sogou"};
    settings.providers["mac_dictionary"].enabled = true;
    settings.providers["sogou"].enabled = true;
    settings.providers["sogou"].endpoint =
        "https://fanyi.sogou.com/api/transpc/hunyuan/translate";
    return settings;
  }

  if (auto order = config.GetList("provider_order")) {
    for (size_t index = 0; index < order->size(); ++index) {
      auto value = order->GetValueAt(index);
      if (value && !value->str().empty()) settings.order.push_back(value->str());
    }
  }
  if (settings.order.empty()) {
    settings.order = {"mac_dictionary", "google", "bing", "youdao_web", "youdao_api",
                      "deepl_web", "deepl", "caiyun_web", "caiyun_api",
                      "sogou"};
  } else if (std::find(settings.order.begin(), settings.order.end(),
                       "mac_dictionary") == settings.order.end()) {
    settings.order.insert(settings.order.begin(), "mac_dictionary");
  }

  for (const std::string& name : settings.order) {
    ProviderConfig provider;
    config.GetBool("providers/" + name + "/enabled", &provider.enabled);
    ReadConfigString(&config, "providers/" + name + "/web_url",
                     &provider.web_url);
    ReadConfigString(&config, "providers/" + name + "/endpoint",
                     &provider.endpoint);
    ReadConfigString(&config, "providers/" + name + "/api_endpoint",
                     &provider.api_endpoint);
    ReadConfigString(&config, "providers/" + name + "/api_key",
                     &provider.api_key);
    ReadConfigString(&config, "providers/" + name + "/token",
                     &provider.token);
    ReadConfigString(&config, "providers/" + name + "/region",
                     &provider.region);
    ReadConfigString(&config, "providers/" + name + "/app_key",
                     &provider.app_key);
    ReadConfigString(&config, "providers/" + name + "/app_secret",
                     &provider.app_secret);
    settings.providers[name] = std::move(provider);
  }
  return settings;
}

std::string Sha256Hex(const std::string& value) {
  unsigned char digest[CC_SHA256_DIGEST_LENGTH] = {};
  CC_SHA256(value.data(), static_cast<CC_LONG>(value.size()), digest);
  static constexpr char kHex[] = "0123456789abcdef";
  std::string result;
  result.reserve(CC_SHA256_DIGEST_LENGTH * 2);
  for (unsigned char byte : digest) {
    result += kHex[byte >> 4];
    result += kHex[byte & 0x0f];
  }
  return result;
}

std::string YoudaoTruncate(const std::string& value) {
  std::vector<size_t> character_offsets{0};
  for (size_t index = 0; index < value.size(); ++index) {
    unsigned char byte = static_cast<unsigned char>(value[index]);
    if ((byte & 0xc0) != 0x80) character_offsets.push_back(index + 1);
  }
  size_t character_count = character_offsets.size() - 1;
  if (character_count <= 20) return value;
  return value.substr(0, character_offsets[10]) +
         std::to_string(character_count) +
         value.substr(character_offsets[character_count - 10]);
}

std::string Md5Binary(const std::string& value) {
  unsigned char digest[CC_MD5_DIGEST_LENGTH] = {};
  CC_MD5(value.data(), static_cast<CC_LONG>(value.size()), digest);
  return std::string(reinterpret_cast<const char*>(digest),
                     CC_MD5_DIGEST_LENGTH);
}

std::string Md5Hex(const std::string& value) {
  std::string binary = Md5Binary(value);
  static constexpr char kHex[] = "0123456789abcdef";
  std::string result;
  result.reserve(binary.size() * 2);
  for (unsigned char byte : binary) {
    result += kHex[byte >> 4];
    result += kHex[byte & 0x0f];
  }
  return result;
}

int Base64Value(unsigned char character) {
  if (character >= 'A' && character <= 'Z') return character - 'A';
  if (character >= 'a' && character <= 'z') return character - 'a' + 26;
  if (character >= '0' && character <= '9') return character - '0' + 52;
  if (character == '+' || character == '-') return 62;
  if (character == '/' || character == '_') return 63;
  return -1;
}

std::string Base64DecodeUrlSafe(const std::string& value) {
  std::string result;
  int accumulator = 0;
  int bits = -8;
  for (unsigned char character : value) {
    if (character == '=' || character == '\r' || character == '\n' ||
        character == ' ' || character == '\t') {
      continue;
    }
    int decoded = Base64Value(character);
    if (decoded < 0) return {};
    accumulator = (accumulator << 6) | decoded;
    bits += 6;
    if (bits >= 0) {
      result.push_back(static_cast<char>((accumulator >> bits) & 0xff));
      bits -= 8;
    }
  }
  return result;
}

std::string DecryptYoudaoWebResponse(const std::string& encrypted) {
  static const std::string kAesKey =
      "ydsecret://query/key/B*RGygVywfNBwpmBaZg*WT7SIOUP2T0C9WHMZN39j^DAdaZhAnxvGcCY6VYFwnHl";
  static const std::string kAesIv =
      "ydsecret://query/iv/C@lZe2YzHtZ2CYgaXKSVfsb7Y4QWHjITPPZ0nQp87fBeJ!Iv6v^6fvi2WN@bYpJ4";
  std::string encrypted_bytes = Base64DecodeUrlSafe(encrypted);
  if (encrypted_bytes.empty()) return {};
  std::string key = Md5Binary(kAesKey);
  std::string iv = Md5Binary(kAesIv);
  std::string result(encrypted_bytes.size() + kCCBlockSizeAES128, '\0');
  size_t result_size = 0;
  CCCryptorStatus status = CCCrypt(
      kCCDecrypt, kCCAlgorithmAES, kCCOptionPKCS7Padding, key.data(),
      kCCKeySizeAES128, iv.data(), encrypted_bytes.data(),
      encrypted_bytes.size(), result.data(), result.size(), &result_size);
  if (status != kCCSuccess) return {};
  result.resize(result_size);
  return result;
}

std::string ToProviderLanguage(const std::string& target,
                               const std::string& provider) {
  if (provider == "youdao" || provider == "youdao_web" ||
      provider == "youdao_api") {
    return target == "zh-CN" ? "zh-CHS" : target;
  }
  if (provider == "bing") {
    return target == "zh-CN" ? "zh-Hans" : target;
  }
  if (target == "zh-CN") return "ZH";
  return target == "en" ? "EN" : target;
}

std::string FetchSogou(const TranslationRequest& request,
                       const ProviderConfig& provider) {
  std::string source = request.target == "en" ? "zh-CHS" : "en";
  std::string body = "{\"text\":" + JsonQuote(request.word) +
                     ",\"from_lang\":" + JsonQuote(source) +
                     ",\"to_lang\":" + JsonQuote(request.target == "en" ? "en" : "zh-CHS") + "}";
  std::string response;
  std::vector<std::string> arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "-X", "POST",
      provider.endpoint.empty()
          ? "https://fanyi.sogou.com/api/transpc/hunyuan/translate"
          : provider.endpoint,
      "-H", "Content-Type: application/json;charset=UTF-8",
      "--data", body};
  if (!RunCommand(arguments, &response)) return {};
  std::string result = ParseJsonField(response, "content");
  return result;
}

std::string FetchYoudaoWeb(const TranslationRequest& request,
                           const ProviderConfig& provider) {
  static const std::string kStaticKey = "asdjnjfenknafdfsdfsd";
  const std::string timestamp =
      std::to_string(static_cast<long long>(time(nullptr)) * 1000);
  const std::string sign1 = Md5Hex(
      "client=fanyideskweb&mysticTime=" + timestamp +
      "&product=webfanyi&key=" + kStaticKey);

  std::string key_response;
  std::vector<std::string> key_arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "--get",
      "https://dict.youdao.com/webtranslate/key",
      "--data-urlencode", "keyid=webfanyi-key-getter",
      "--data-urlencode", "sign=" + sign1,
      "--data-urlencode", "client=fanyideskweb",
      "--data-urlencode", "product=webfanyi",
      "--data-urlencode", "appVersion=1.0.0",
      "--data-urlencode", "vendor=web",
      "--data-urlencode", "pointParam=client,mysticTime,product",
      "--data-urlencode", "mysticTime=" + timestamp,
      "--data-urlencode", "keyfrom=fanyi.web",
      "-H", "Referer: https://fanyi.youdao.com/",
      "-H", "Cookie: OUTFOX_SEARCH_USER_ID=0@0.0.0.0;"};
  if (!RunCommand(key_arguments, &key_response)) return {};
  std::string secret_key = ParseJsonField(key_response, "secretKey");
  if (secret_key.empty()) secret_key = kStaticKey;

  const std::string sign2 = Md5Hex(
      "client=fanyideskweb&mysticTime=" + timestamp +
      "&product=webfanyi&key=" + secret_key);
  std::string response;
  std::string endpoint = provider.endpoint.empty()
                             ? "https://dict.youdao.com/webtranslate"
                             : provider.endpoint;
  std::vector<std::string> arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "-X", "POST", endpoint,
      "-H", "Content-Type: application/x-www-form-urlencoded",
      "-H", "User-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
             "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 "
             "Safari/537.36",
      "-H", "Referer: https://fanyi.youdao.com/",
      "-H", "Cookie: OUTFOX_SEARCH_USER_ID=0@0.0.0.0;",
      "--data-urlencode", "i=" + request.word,
      "--data-urlencode", std::string("from=") +
          (request.target == "en" ? "zh-CN" : "en"),
      "--data-urlencode", "to=" +
          ToProviderLanguage(request.target, "youdao_api"),
      "--data-urlencode", "dictResult=false",
      "--data-urlencode", "keyid=webfanyi",
      "--data-urlencode", "sign=" + sign2,
      "--data-urlencode", "client=fanyideskweb",
      "--data-urlencode", "product=webfanyi",
      "--data-urlencode", "appVersion=1.0.0",
      "--data-urlencode", "vendor=web",
      "--data-urlencode", "pointParam=client,mysticTime,product",
      "--data-urlencode", "mysticTime=" + timestamp,
      "--data-urlencode", "keyfrom=fanyi.web"};
  if (!RunCommand(arguments, &response)) return {};
  std::string decrypted = DecryptYoudaoWebResponse(response);
  if (decrypted.empty() || decrypted.find("opt-out of paragraphs") !=
                                std::string::npos) {
    return {};
  }
  return ParseJsonAllStringFields(decrypted, "tgt");
}

std::string FetchYoudaoApi(const TranslationRequest& request,
                           const ProviderConfig& provider) {
  if (provider.app_key.empty() || provider.app_secret.empty()) return {};
  static std::atomic<uint64_t> salt_sequence{0};
  std::string salt = std::to_string(static_cast<long long>(time(nullptr))) +
                     "-" + std::to_string(static_cast<long long>(getpid())) +
                     "-" + std::to_string(salt_sequence.fetch_add(1));
  std::string curtime = salt;
  std::string query = YoudaoTruncate(request.word);
  std::string sign = Sha256Hex(provider.app_key + query + salt + curtime +
                               provider.app_secret);
  std::string response;
  std::vector<std::string> arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "--get",
      provider.api_endpoint.empty() ? "https://openapi.youdao.com/api"
                                    : provider.api_endpoint,
      "--data-urlencode", "q=" + request.word,
      "--data-urlencode", "from=auto",
      "--data-urlencode", "to=" + ToProviderLanguage(request.target, "youdao"),
      "--data-urlencode", "appKey=" + provider.app_key,
      "--data-urlencode", "salt=" + salt,
      "--data-urlencode", "sign=" + sign,
      "--data-urlencode", "signType=v3",
      "--data-urlencode", "curtime=" + curtime};
  if (!RunCommand(arguments, &response)) return {};
  return ParseJsonFirstArrayString(response, "translation");
}

std::string FetchDeepL(const TranslationRequest& request,
                       const ProviderConfig& provider) {
  if (provider.api_key.empty()) return {};
  std::string response;
  std::vector<std::string> arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "-X", "POST",
      provider.endpoint.empty() ? "https://api-free.deepl.com/v2/translate"
                                : provider.endpoint,
      "-H", "Authorization: DeepL-Auth-Key " + provider.api_key,
      "--data-urlencode", "text=" + request.word,
      "--data-urlencode", "target_lang=" +
          ToProviderLanguage(request.target, "deepl")};
  if (!RunCommand(arguments, &response)) return {};
  return ParseJsonField(response, "text");
}

class DeepLWebClient {
 public:
  static DeepLWebClient& Instance() {
    static DeepLWebClient client;
    return client;
  }

  bool Translate(const std::string& endpoint, const std::string& target,
                 const std::string& text, std::string* output) {
    std::lock_guard<std::mutex> lock(mutex_);
    for (int attempt = 0; attempt < 2; ++attempt) {
      if (!EnsureStarted(endpoint)) return false;
      const std::string request = target + "\t" + CleanField(text) + "\n";
      if (WriteAll(request)) {
        std::string line;
        if (ReadLine(&line) && line.compare(0, 3, "OK\t") == 0) {
          *output = CleanField(line.substr(3));
          return !output->empty();
        }
      }
      StopLocked();
    }
    return false;
  }

  void Stop() {
    std::lock_guard<std::mutex> lock(mutex_);
    StopLocked();
  }

 private:
  bool EnsureStarted(const std::string& endpoint) {
    if (child_ > 0 && endpoint_ == endpoint) return true;
    StopLocked();

    int input_pipe[2] = {-1, -1};
    int output_pipe[2] = {-1, -1};
    if (pipe(input_pipe) != 0) return false;
    if (pipe(output_pipe) != 0) {
      close(input_pipe[0]);
      close(input_pipe[1]);
      return false;
    }

    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, input_pipe[0], STDIN_FILENO);
    posix_spawn_file_actions_adddup2(&actions, output_pipe[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&actions, input_pipe[0]);
    posix_spawn_file_actions_addclose(&actions, input_pipe[1]);
    posix_spawn_file_actions_addclose(&actions, output_pipe[0]);
    posix_spawn_file_actions_addclose(&actions, output_pipe[1]);

    std::vector<std::string> arguments = {
        kPythonPath, kDeepLWebScriptPath, "--server", "--endpoint", endpoint,
        "--timeout", "12"};
    std::vector<char*> argv;
    argv.reserve(arguments.size() + 1);
    for (const std::string& argument : arguments) {
      argv.push_back(const_cast<char*>(argument.c_str()));
    }
    argv.push_back(nullptr);

    pid_t child = 0;
    const int result = posix_spawn(&child, kPythonPath, &actions, nullptr,
                                   argv.data(), environ);
    posix_spawn_file_actions_destroy(&actions);
    close(input_pipe[0]);
    close(output_pipe[1]);
    if (result != 0) {
      close(input_pipe[1]);
      close(output_pipe[0]);
      return false;
    }

    child_ = child;
    input_fd_ = input_pipe[1];
    output_fd_ = output_pipe[0];
#ifdef F_SETNOSIGPIPE
    fcntl(input_fd_, F_SETNOSIGPIPE, 1);
#endif
    endpoint_ = endpoint;
    read_buffer_.clear();
    return true;
  }

  bool WriteAll(const std::string& value) {
    size_t offset = 0;
    while (offset < value.size()) {
      const ssize_t count =
          write(input_fd_, value.data() + offset, value.size() - offset);
      if (count > 0) {
        offset += static_cast<size_t>(count);
      } else if (count < 0 && errno == EINTR) {
        continue;
      } else {
        return false;
      }
    }
    return true;
  }

  bool ReadLine(std::string* line) {
    for (;;) {
      const size_t newline = read_buffer_.find('\n');
      if (newline != std::string::npos) {
        *line = read_buffer_.substr(0, newline);
        read_buffer_.erase(0, newline + 1);
        return true;
      }
      struct pollfd descriptor {output_fd_, POLLIN | POLLHUP, 0};
      int ready = 0;
      do {
        ready = poll(&descriptor, 1, 26000);
      } while (ready < 0 && errno == EINTR);
      if (ready <= 0) return false;
      char buffer[4096];
      const ssize_t count = read(output_fd_, buffer, sizeof(buffer));
      if (count <= 0) return false;
      read_buffer_.append(buffer, static_cast<size_t>(count));
      if (read_buffer_.size() > 64 * 1024) return false;
    }
  }

  void StopLocked() {
    if (input_fd_ >= 0) close(input_fd_);
    if (output_fd_ >= 0) close(output_fd_);
    input_fd_ = -1;
    output_fd_ = -1;
    read_buffer_.clear();
    endpoint_.clear();
    if (child_ > 0) {
      kill(child_, SIGTERM);
      int status = 0;
      while (waitpid(child_, &status, 0) < 0 && errno == EINTR) {
      }
      child_ = 0;
    }
  }

  DeepLWebClient() = default;
  ~DeepLWebClient() { StopLocked(); }
  DeepLWebClient(const DeepLWebClient&) = delete;
  DeepLWebClient& operator=(const DeepLWebClient&) = delete;

  std::mutex mutex_;
  pid_t child_ = 0;
  int input_fd_ = -1;
  int output_fd_ = -1;
  std::string endpoint_;
  std::string read_buffer_;
};

std::string FetchDeepLWeb(const TranslationRequest& request,
                          const ProviderConfig& provider) {
  std::string endpoint = provider.endpoint;
  if (endpoint.empty() || endpoint.find("jsonrpc") != std::string::npos) {
    endpoint = "https://ita-free.www.deepl.com/v2";
  }
  std::string response;
  if (!DeepLWebClient::Instance().Translate(
          endpoint, ToProviderLanguage(request.target, "deepl"), request.word,
          &response)) {
    return {};
  }
  return response;
}

std::string FetchCaiyun(const TranslationRequest& request,
                        const ProviderConfig& provider) {
  if (provider.token.empty()) return {};
  const std::string target = request.target == "zh-CN"
                                 ? "zh"
                                 : request.target == "zh-TW"
                                       ? "zh-Hant"
                                       : request.target;
  const std::string trans_type = "auto2" + target;
  const std::string body =
      "{\"source\":[" + JsonQuote(request.word) +
      "],\"trans_type\":" + JsonQuote(trans_type) +
      ",\"detect\":true,\"media\":\"text\","
      "\"request_id\":\"squirrel-translation\"}";
  std::string response;
  std::vector<std::string> arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "-X", "POST",
      provider.endpoint.empty()
          ? "https://api.interpreter.caiyunai.com/v1/translator"
          : provider.endpoint,
      "-H", "Content-Type: application/json",
      "-H", "X-Authorization: token " + provider.token,
      "--data", body};
  if (!RunCommand(arguments, &response)) return {};
  return ParseJsonFirstArrayString(response, "target");
}

struct CaiyunWebCredentials {
  std::string app_token;
  std::string jwt;
  std::string browser_id;
  std::string version;
  time_t expires = 0;
};

void LogCaiyunWebFailure(const std::string& stage) {
  static std::mutex log_mutex;
  std::lock_guard<std::mutex> lock(log_mutex);
  std::ofstream file("/tmp/squirrel-translation-caiyun.log",
                     std::ios::out | std::ios::app);
  if (!file) return;
  file << static_cast<long long>(time(nullptr)) << '\t' << stage << '\n';
}

bool LoadCaiyunWebCredentials(const ProviderConfig& provider,
                              CaiyunWebCredentials* credentials) {
  std::string page;
  const std::string web_url = provider.web_url.empty()
                                  ? "https://fanyi.caiyunapp.com/"
                                  : provider.web_url;
  std::vector<std::string> page_arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "-A", "Mozilla/5.0",
      web_url};
  if (!RunCommand(page_arguments, &page, 256 * 1024)) {
    LogCaiyunWebFailure("page_request");
    return false;
  }

  const std::string source_marker = "src=\"/dist/assets/";
  size_t source_position = page.find(source_marker);
  if (source_position == std::string::npos) {
    LogCaiyunWebFailure("page_script_missing");
    return false;
  }
  source_position += 5;
  size_t source_end = page.find('"', source_position);
  if (source_end == std::string::npos) {
    LogCaiyunWebFailure("page_script_invalid");
    return false;
  }
  const std::string script_url =
      "https://fanyi.caiyunapp.com" +
      page.substr(source_position, source_end - source_position);

  std::string script;
  std::vector<std::string> script_arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "-A", "Mozilla/5.0", script_url};
  if (!RunCommand(script_arguments, &script, 1024 * 1024)) {
    LogCaiyunWebFailure("script_request");
    return false;
  }

  const std::string app_token_marker = "const Xk=\"";
  size_t app_token_position = script.find(app_token_marker);
  if (app_token_position == std::string::npos) {
    LogCaiyunWebFailure("app_token_missing");
    return false;
  }
  app_token_position += app_token_marker.size();
  size_t app_token_end = script.find('"', app_token_position);
  if (app_token_end == std::string::npos) {
    LogCaiyunWebFailure("app_token_invalid");
    return false;
  }
  credentials->app_token =
      script.substr(app_token_position, app_token_end - app_token_position);
  if (credentials->app_token.empty()) {
    LogCaiyunWebFailure("app_token_empty");
    return false;
  }

  const std::string version_marker = "const A0=\"";
  size_t version_position = script.find(version_marker);
  if (version_position != std::string::npos) {
    version_position += version_marker.size();
    size_t version_end = script.find('"', version_position);
    if (version_end != std::string::npos) {
      credentials->version =
          script.substr(version_position, version_end - version_position);
    }
  }
  if (credentials->version.empty()) credentials->version = "4.7.0";

  credentials->browser_id =
      Md5Hex("squirrel-translation-caiyun-web:" +
             std::to_string(static_cast<long long>(getpid())));
  std::string token_endpoint = kCaiyunApiEndpoint;
  const std::string suffix = "/v1/translator";
  size_t suffix_position = token_endpoint.rfind(suffix);
  token_endpoint.replace(suffix_position, suffix.size(),
                         "/v1/user/jwt/generate");
  const std::string body =
      "{\"browser_id\":" + JsonQuote(credentials->browser_id) + "}";
  std::string response;
  std::vector<std::string> token_arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "-X", "POST", token_endpoint,
      "-H", "Content-Type: application/json",
      "-H", "X-Authorization: " + credentials->app_token,
      "-H", "App-Name: xiaoyi",
      "-H", "os-type: web",
      "-H", "device-id: " + credentials->browser_id,
      "-H", "Origin: https://fanyi.caiyunapp.com",
      "-H", "Referer: https://fanyi.caiyunapp.com/",
      "-A", "Mozilla/5.0", "--data", body};
  if (!RunCommand(token_arguments, &response)) {
    LogCaiyunWebFailure("jwt_request");
    return false;
  }
  credentials->jwt = ParseJsonField(response, "jwt");
  if (credentials->jwt.empty()) {
    LogCaiyunWebFailure("jwt_missing");
    return false;
  }
  const long long expire_time = ParseJsonIntegerField(response, "expire_time");
  credentials->expires = expire_time > time(nullptr) + 60
                             ? static_cast<time_t>(expire_time - 30)
                             : time(nullptr) + 9 * 60;
  return true;
}

std::string DecodeCaiyunWebTarget(std::string value) {
  for (char& character : value) {
    if (character >= 'A' && character <= 'Z') {
      character = static_cast<char>('A' + (character - 'A' + 13) % 26);
    } else if (character >= 'a' && character <= 'z') {
      character = static_cast<char>('a' + (character - 'a' + 13) % 26);
    }
  }
  return Base64DecodeUrlSafe(value);
}

std::string FetchCaiyunWeb(const TranslationRequest& request,
                           const ProviderConfig& provider) {
  static CaiyunWebCredentials credentials;
  static std::mutex credentials_mutex;
  std::lock_guard<std::mutex> lock(credentials_mutex);
  if (credentials.jwt.empty() || credentials.expires <= time(nullptr)) {
    credentials = {};
    if (!LoadCaiyunWebCredentials(provider, &credentials)) return {};
  }
  const std::string target = request.target == "zh-CN"
                                 ? "zh"
                                 : request.target == "zh-TW"
                                       ? "zh-Hant"
                                       : request.target;
  const std::string body =
      "{\"source\":[" + JsonQuote(request.word) +
      "],\"trans_type\":" + JsonQuote("auto2" + target) +
      ",\"detect\":true,\"media\":\"text\","
      "\"request_id\":\"web_fanyi\",\"os_type\":\"web\","
      "\"dict\":true,\"cached\":true,\"replaced\":true,"
      "\"model\":\"\",\"browser_id\":" + JsonQuote(credentials.browser_id) + "}";
  std::string response;
  std::vector<std::string> arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "-X", "POST",
      kCaiyunApiEndpoint,
      "-H", "Content-Type: application/json",
      "-H", "T-Authorization: " + credentials.jwt,
      "-H", "X-Authorization: " + credentials.app_token,
      "-H", "App-Name: xiaoyi",
      "-H", "Accept-Language: zh-CN",
      "-H", "os-type: web",
      "-H", "device-id: " + credentials.browser_id,
      "-H", "version: " + credentials.version,
      "-H", "Origin: https://fanyi.caiyunapp.com",
      "-H", "Referer: https://fanyi.caiyunapp.com/",
      "-A", "Mozilla/5.0",
      "--data", body};
  if (!RunCommand(arguments, &response)) {
    LogCaiyunWebFailure("translation_request");
    credentials.jwt.clear();
    return {};
  }
  std::string result = ParseJsonField(response, "target");
  if (result.empty()) result = ParseJsonFirstArrayString(response, "target");
  if (result.empty()) {
    LogCaiyunWebFailure("translation_target_missing");
    credentials.jwt.clear();
    return {};
  }
  std::string decoded = DecodeCaiyunWebTarget(result);
  if (!decoded.empty()) {
    result = std::move(decoded);
  } else {
    LogCaiyunWebFailure("translation_decode_failed");
  }
  return result;
}

std::string FetchGoogle(const TranslationRequest& request,
                        const ProviderConfig& provider) {
  std::string endpoint = provider.endpoint.empty()
                             ? "https://translate.google.com/translate_a/single"
                             : provider.endpoint;
  std::string response;
  std::vector<std::string> arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "-A",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
      "--get", endpoint,
      "--data-urlencode", "client=gtx",
      "--data-urlencode", std::string("sl=") +
          (request.target == "en" ? "zh-CN" : "en"),
      "--data-urlencode", std::string("tl=") +
          (request.target == "en" ? "en" : "zh-CN"),
      "--data-urlencode", "dt=t",
      "--data-urlencode", "dj=1",
      "--data-urlencode", "ie=UTF-8",
      "--data-urlencode", "q=" + request.word};
  if (!RunCommand(arguments, &response)) return {};
  return ParseJsonAllStringFields(response, "trans");
}

struct BingCredentials {
  std::string ig;
  std::string iid;
  std::string key;
  std::string token;
  time_t expires = 0;
};

bool ParseBingCredentials(const std::string& body, BingCredentials* credentials) {
  size_t ig_marker = body.find("IG:\"");
  if (ig_marker == std::string::npos) return false;
  ig_marker += 4;
  size_t ig_end = body.find('"', ig_marker);
  if (ig_end == std::string::npos) return false;
  credentials->ig = body.substr(ig_marker, ig_end - ig_marker);

  size_t iid_marker = body.find("data-iid=\"");
  if (iid_marker == std::string::npos) return false;
  iid_marker += 10;
  size_t iid_end = body.find('"', iid_marker);
  if (iid_end == std::string::npos) return false;
  credentials->iid = body.substr(iid_marker, iid_end - iid_marker);

  size_t params_marker = body.find("params_AbusePreventionHelper");
  if (params_marker == std::string::npos) return false;
  size_t array_start = body.find('[', params_marker);
  size_t array_end = body.find(']', array_start);
  if (array_start == std::string::npos || array_end == std::string::npos) {
    return false;
  }

  std::vector<std::string> values;
  size_t position = array_start + 1;
  while (position < array_end && values.size() < 3) {
    position = body.find_first_not_of(" \t\r\n,", position);
    if (position == std::string::npos || position >= array_end) break;
    if (body[position] == '"') {
      std::string value;
      size_t end_position = 0;
      if (!ParseJsonStringAt(body, position, &value, &end_position)) return false;
      values.push_back(value);
      position = end_position;
    } else {
      size_t end_position = body.find_first_of(",]", position);
      if (end_position == std::string::npos || end_position > array_end) {
        end_position = array_end;
      }
      values.push_back(CleanField(body.substr(position, end_position - position)));
      position = end_position;
    }
  }
  if (values.size() < 3 || values[0].empty() || values[1].empty()) return false;
  credentials->key = values[0];
  credentials->token = values[1];
  long long expiry_ms = std::strtoll(values[2].c_str(), nullptr, 10);
  if (expiry_ms <= 0) expiry_ms = 1800000;
  credentials->expires = time(nullptr) + expiry_ms / 1000 - 60;
  return true;
}

std::string FetchBing(const TranslationRequest& request,
                      const ProviderConfig& provider) {
  std::string endpoint = provider.endpoint.empty()
                             ? "https://cn.bing.com/translator"
                             : provider.endpoint;

  static BingCredentials credentials;
  if (credentials.expires <= time(nullptr)) {
    std::string token_page;
    std::vector<std::string> token_arguments = {
        kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
        "--connect-timeout", "2", "-A",
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        "--compressed",
        endpoint};
    if (!RunCommand(token_arguments, &token_page,
                    kBingTokenPageOutputLimit) ||
        !ParseBingCredentials(token_page, &credentials)) {
      credentials = {};
      return {};
    }
  }

  std::string url = "https://cn.bing.com/ttranslatev3?isVertical=1&IG=" +
                    credentials.ig + "&IID=" + credentials.iid;
  std::string response;
  std::vector<std::string> arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "5",
      "--connect-timeout", "2", "-A",
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
      "-X", "POST", url,
      "-H", "Content-Type: application/x-www-form-urlencoded",
      "-H", "Referer: https://cn.bing.com/translator",
      "-H", "Accept-Encoding: gzip, deflate",
      "--compressed",
      "--data-urlencode", std::string("fromLang=") +
          (request.target == "en" ? "zh-Hans" : "en"),
      "--data-urlencode", "to=" + ToProviderLanguage(request.target, "bing"),
      "--data-urlencode", "text=" + request.word,
      "--data-urlencode", "token=" + credentials.token,
      "--data-urlencode", "key=" + credentials.key};
  if (!RunCommand(arguments, &response)) return {};
  return ParseJsonField(response, "text");
}

std::string FetchTranslation(const TranslationRequest& request,
                             const std::string& provider_config_path,
                             std::string* provider_name) {
  if (provider_name) provider_name->clear();
  ProviderSettings settings = LoadProviderSettings(provider_config_path);
  const auto local = settings.providers.find("mac_dictionary");
  const bool local_enabled =
      local != settings.providers.end() && local->second.enabled;
  if (local_enabled) {
    const std::string local_result = FetchMacDictionary(request);
    if (!local_result.empty()) {
      if (provider_name) *provider_name = "mac_dictionary";
      return local_result;
    }
    if (!request.allow_online_fallback) return {};
  }

  const auto caiyun_api = settings.providers.find("caiyun_api");
  const bool caiyun_api_enabled =
      caiyun_api != settings.providers.end() && caiyun_api->second.enabled;
  for (const std::string& name : settings.order) {
    auto found = settings.providers.find(name);
    if (found == settings.providers.end() || !found->second.enabled) continue;
    if (name == "mac_dictionary") continue;
    if (name == "caiyun_web" && caiyun_api_enabled) continue;
    const ProviderConfig& provider = found->second;
    std::string result;
    if (name == "sogou") {
      result = FetchSogou(request, provider);
    } else if (name == "youdao_web") {
      result = FetchYoudaoWeb(request, provider);
    } else if (name == "youdao_api") {
      result = FetchYoudaoApi(request, provider);
    } else if (name == "deepl_web") {
      result = FetchDeepLWeb(request, provider);
    } else if (name == "deepl") {
      result = FetchDeepL(request, provider);
    } else if (name == "caiyun_web") {
      result = FetchCaiyunWeb(request, provider);
    } else if (name == "caiyun_api") {
      result = FetchCaiyun(request, provider);
    } else if (name == "google") {
      result = FetchGoogle(request, provider);
    } else if (name == "bing") {
      result = FetchBing(request, provider);
    }
    if (!result.empty()) {
      if (provider_name) *provider_name = name;
      return result;
    }
  }
  return {};
}

std::string FetchPhoneticSingle(const std::string& word) {
  std::string response;
  std::vector<std::string> arguments = {
      kCurlPath, "-L", "--silent", "--show-error", "--max-time", "2",
      "--connect-timeout", "1", "--get", "https://dict.youdao.com/jsonapi",
      "--data-urlencode", "q=" + word,
      "--data-urlencode",
      "dicts={\"count\":99,\"dicts\":[[\"ec\",\"ce\"]]}"};
  if (!RunCommand(arguments, &response)) return {};
  std::string phonetic = ParseJsonField(response, "usphone");
  if (phonetic.empty()) phonetic = ParseJsonField(response, "ukphone");
  if (phonetic.empty()) phonetic = ParseJsonField(response, "phonetic");
  return phonetic;
}

std::vector<std::string> ExtractEnglishWords(const std::string& value) {
  std::vector<std::string> words;
  std::string current;
  for (unsigned char character : value) {
    const bool ascii_letter =
        (character >= 'A' && character <= 'Z') ||
        (character >= 'a' && character <= 'z');
    if (ascii_letter) {
      current += static_cast<char>(character);
    } else if (current.size() >= 2) {
      words.push_back(current);
      current.clear();
    } else {
      current.clear();
    }
  }
  if (current.size() >= 2) words.push_back(current);
  return words;
}

std::string FetchPhonetic(const std::string& value) {
  if (value.empty()) return {};
  if (IsEnglishWord(value) && value.find(' ') == std::string::npos) {
    return FetchPhoneticSingle(value);
  }

  // The dictionary endpoint often has no pronunciation for phrases, digits,
  // or curly punctuation. Query their ASCII words separately.
  const std::vector<std::string> words = ExtractEnglishWords(value);
  std::string result;
  for (const std::string& word : words) {
    std::string phonetic = FetchPhoneticSingle(word);
    if (phonetic.empty()) continue;
    if (!result.empty()) result += " ";
    result += phonetic;
  }
  return result;
}

struct FileSignature {
  bool exists = false;
  dev_t device = 0;
  ino_t inode = 0;
  off_t size = 0;
  time_t modified_seconds = 0;
  long modified_nanoseconds = 0;

  bool operator==(const FileSignature& other) const {
    return exists == other.exists && device == other.device &&
           inode == other.inode && size == other.size &&
           modified_seconds == other.modified_seconds &&
           modified_nanoseconds == other.modified_nanoseconds;
  }

  bool operator!=(const FileSignature& other) const {
    return !(*this == other);
  }
};

FileSignature ReadSignature(const std::string& path) {
  struct stat status {};
  if (stat(path.c_str(), &status) != 0) {
    return {};
  }
  return {
      true,
      status.st_dev,
      status.st_ino,
      status.st_size,
      status.st_mtimespec.tv_sec,
      status.st_mtimespec.tv_nsec,
  };
}

struct ContextRegistration {
  explicit ContextRegistration(rime::Context* value) : context(value) {}

  std::atomic<bool> alive{true};
  rime::Context* context = nullptr;
  rime::connection update_connection;
};

class RefreshManager {
 public:
  static RefreshManager& Instance() {
    static RefreshManager instance;
    return instance;
  }

  void Start() {
    bool expected = false;
    if (!running_.compare_exchange_strong(expected, true)) {
      return;
    }

    char user_data_dir[PATH_MAX] = {};
    RimeApi* api = rime_get_api();
    if (api && api->get_user_data_dir_s) {
      api->get_user_data_dir_s(user_data_dir, sizeof(user_data_dir));
    }
    if (user_data_dir[0] == '\0') {
      const char* home = std::getenv("HOME");
      if (home) {
        user_dir_ = std::string(home) + "/Library/Rime";
      }
    } else {
      user_dir_ = user_data_dir;
    }

    if (user_dir_.empty()) {
      running_.store(false);
      return;
    }

    runtime_dir_ = user_dir_;

    cache_path_ = runtime_dir_ + "/input_translation.cache.tsv";
    emoji_cache_path_ = runtime_dir_ + "/input_translation.emoji.cache.tsv";
    cache_temp_path_ = cache_path_ + ".tmp";
    emoji_cache_temp_path_ = emoji_cache_path_ + ".tmp";
    request_path_ = runtime_dir_ + "/input_translation.requests.tsv";
    emoji_request_path_ = runtime_dir_ + "/input_translation.emoji.requests.tsv";
    speech_request_path_ = runtime_dir_ + "/input_translation.speech.requests.tsv";
    provider_config_path_ = runtime_dir_ + "/translation.providers.yaml";
    LoadCache();
    lifecycle_.fetch_add(1);
    for (size_t index = 0; index < kTranslationWorkerCount; ++index) {
      translation_workers_.emplace_back(
          [this] { TranslateQueuedRequests(); });
    }
    worker_ = std::thread([this] { WatchDirectory(); });
  }

  void Stop() {
    if (!running_.exchange(false)) {
      return;
    }

    lifecycle_.fetch_add(1);
    int queue = kqueue_fd_.load();
    if (queue >= 0) {
      struct kevent event {};
      EV_SET(&event, kStopEvent, EVFILT_USER, 0, NOTE_TRIGGER, 0, nullptr);
      kevent(queue, &event, 1, nullptr, 0, nullptr);
    }
    if (worker_.joinable()) {
      worker_.join();
    }
    {
      std::lock_guard<std::mutex> lock(translation_mutex_);
      translation_wakeup_.notify_all();
    }
    for (auto& worker : translation_workers_) {
      if (worker.joinable()) worker.join();
    }
    translation_workers_.clear();

    dispatch_pending_.store(false);
    std::lock_guard<std::mutex> lock(registrations_mutex_);
    registrations_.clear();
  }

  std::shared_ptr<ContextRegistration> Register(rime::Context* context) {
    auto registration = std::make_shared<ContextRegistration>(context);
    if (context) {
      std::weak_ptr<ContextRegistration> weak_registration = registration;
      registration->update_connection = context->update_notifier().connect(
          [this, weak_registration](rime::Context* updated_context) {
            auto active = weak_registration.lock();
            if (active) HandleContextUpdate(active, updated_context);
          });
    }
    std::lock_guard<std::mutex> lock(registrations_mutex_);
    registrations_.push_back(registration);
    return registration;
  }

  void Unregister(const std::shared_ptr<ContextRegistration>& registration) {
    if (!registration) {
      return;
    }
    registration->alive.store(false);
    std::lock_guard<std::mutex> lock(registrations_mutex_);
    auto output = registrations_.begin();
    for (auto item = registrations_.begin(); item != registrations_.end();
         ++item) {
      auto active = item->lock();
      if (active && active != registration && active->alive.load()) {
        *output++ = *item;
      }
    }
    registrations_.erase(output, registrations_.end());
  }

 private:
  void HandleContextUpdate(
      const std::shared_ptr<ContextRegistration>& registration,
      rime::Context* context) {
    if (!registration->alive.load() || context != registration->context ||
        !context->HasMenu() ||
        !context->get_property(kRefreshSelectionProperty).empty()) {
      return;
    }
    auto selected = context->GetSelectedCandidate();
    if (!selected) return;
    std::string remembered =
        context->get_property(kSelectedCandidateProperty);
    if (remembered == selected->text()) return;
    context->set_property(kSelectedCandidateProperty, selected->text());
  }

  struct DispatchTask {
    RefreshManager* manager = nullptr;
    uint64_t lifecycle = 0;
  };

  RefreshManager() = default;
  ~RefreshManager() { Stop(); }
  RefreshManager(const RefreshManager&) = delete;
  RefreshManager& operator=(const RefreshManager&) = delete;

  void LoadCache() {
    std::ifstream file(cache_path_);
    if (!file) return;
    std::string line;
    std::lock_guard<std::mutex> lock(translation_mutex_);
    while (std::getline(file, line)) {
      std::vector<std::string> fields = SplitTabs(line);
      if (fields.size() < 3) continue;
      CacheEntry entry{CleanField(fields[0]), CleanField(fields[1]),
                       CleanField(fields[2]),
                       fields.size() > 3 ? CleanField(fields[3]) : "",
                       fields.size() > 4 ? CleanField(fields[4]) : ""};
      if (entry.target.empty() || entry.word.empty() ||
          entry.translation.empty()) {
        continue;
      }
      // DeepL occasionally returns the source text unchanged for a short or
      // ambiguous Chinese fragment.  It is not an English translation and
      // must not survive as a usable cache entry.
      if (entry.target == "en" && entry.word == entry.translation) {
        continue;
      }
      std::string key = CacheKey(entry.target, entry.word);
      if (cache_.find(key) == cache_.end()) cache_order_.push_back(key);
      cache_[key] = std::move(entry);
    }
    while (cache_order_.size() > kCacheLimit) {
      cache_.erase(cache_order_.front());
      cache_order_.pop_front();
    }
  }

  void ReadTranslationRequests() {
    ReadRequestFile(request_path_, false);
    ReadRequestFile(emoji_request_path_, true);
    ReadSpeechRequests();
  }

  void ReadRequestFile(const std::string& path, bool emoji) {
    std::ifstream file(path);
    if (!file) return;
    std::streamoff* offset = emoji ? &emoji_request_offset_ : &request_offset_;
    file.seekg(0, std::ios::end);
    std::streamoff size = file.tellg();
    if (size < *offset) *offset = 0;
    file.seekg(*offset, std::ios::beg);
    std::string line;
    while (std::getline(file, line)) {
      std::vector<std::string> fields = SplitTabs(line);
      if (fields.empty()) continue;
      std::string word = CleanField(fields[0]);
      std::string target = emoji ? "" :
          CleanField(fields.size() > 1 ? fields[1] : "en");
      const bool allow_online_fallback =
          fields.size() < 4 || CleanField(fields[3]) != "0";
      const bool requested_phonetic =
          fields.size() >= 5 && CleanField(fields[4]) == "phonetic";
      if (word.empty() || (!emoji && target.empty())) continue;
      std::string key = emoji ? std::string("emoji") + '\0' + word
                              : CacheKey(target, word);
      bool phonetic_only = false;
      std::string phonetic_word;
      {
        std::lock_guard<std::mutex> lock(translation_mutex_);
        auto cached = cache_.find(key);
        phonetic_only = !emoji && cached != cache_.end() &&
                        cached->second.phonetic.empty() &&
                        (requested_phonetic ||
                         IsEnglishWord(cached->second.translation));
        if (phonetic_only) phonetic_word = cached->second.translation;
      }
      TranslationRequest request{word, target, emoji, phonetic_only, false,
                                 phonetic_word, allow_online_fallback};
      std::lock_guard<std::mutex> lock(translation_mutex_);
      if (!emoji && cache_.find(key) != cache_.end() && !phonetic_only) {
        continue;
      }
      if (pending_requests_.find(key) != pending_requests_.end()) {
        if (allow_online_fallback) {
          bool found_queued = false;
          for (auto& queued_request : translation_queue_) {
            if (RequestKey(queued_request) == key) {
              queued_request.allow_online_fallback = true;
              found_queued = true;
              break;
            }
          }
          if (!found_queued && active_online_requests_.find(key) ==
                                  active_online_requests_.end()) {
            online_upgrade_requests_.insert(key);
          }
        }
        continue;
      }
      if (translation_queue_.size() >= kTranslationQueueLimit) {
        const TranslationRequest dropped = translation_queue_.front();
        translation_queue_.pop_front();
        pending_requests_.erase(RequestKey(dropped));
      }
      translation_queue_.push_back(std::move(request));
      pending_requests_.insert(key);
      translation_wakeup_.notify_one();
    }
    std::streamoff new_offset = file.tellg();
    *offset = new_offset < 0 ? size : new_offset;
  }

  void ReadSpeechRequests() {
    std::ifstream file(speech_request_path_);
    if (!file) return;
    file.seekg(0, std::ios::end);
    std::streamoff size = file.tellg();
    if (size < speech_request_offset_) speech_request_offset_ = 0;
    file.seekg(speech_request_offset_, std::ios::beg);
    std::string line;
    while (std::getline(file, line)) {
      std::string word = CleanField(line);
      if (word.empty()) continue;
      TranslationRequest request{word, "", false, false, true, ""};
      std::string key = RequestKey(request);
      std::lock_guard<std::mutex> lock(translation_mutex_);
      if (pending_requests_.find(key) != pending_requests_.end()) continue;
      if (translation_queue_.size() >= kTranslationQueueLimit) {
        const TranslationRequest dropped = translation_queue_.front();
        translation_queue_.pop_front();
        pending_requests_.erase(RequestKey(dropped));
      }
      translation_queue_.push_back(std::move(request));
      pending_requests_.insert(key);
      translation_wakeup_.notify_one();
    }
    std::streamoff new_offset = file.tellg();
    speech_request_offset_ = new_offset < 0 ? size : new_offset;
  }

  void TranslateQueuedRequests() {
    while (running_.load()) {
      TranslationRequest request;
      std::string request_key;
      {
        std::unique_lock<std::mutex> lock(translation_mutex_);
        translation_wakeup_.wait(lock, [this] {
          return !running_.load() || !translation_queue_.empty();
        });
        if (!running_.load()) break;
        request = std::move(translation_queue_.front());
        translation_queue_.pop_front();
        request_key = RequestKey(request);
        if (request.allow_online_fallback) {
          active_online_requests_.insert(request_key);
        }
      }

      bool translation_saved = false;
      if (request.speak_only) {
        std::string output;
        RunCommand({"/usr/bin/say", request.word}, &output);
      } else if (request.emoji) {
        std::string name = FetchEmojiName(request.word);
        if (!name.empty()) SaveEmojiCache(request.word, name);
      } else if (request.phonetic_only) {
        const std::string phonetic_word =
            request.phonetic_word.empty() ? request.word : request.phonetic_word;
        std::string phonetic;
        if (request.allow_online_fallback) {
          phonetic = FetchMacDictionaryPhonetic(phonetic_word);
        }
        if (phonetic.empty()) phonetic = FetchPhonetic(phonetic_word);
        if (!phonetic.empty()) UpdatePhonetic(request, phonetic);
      } else {
        std::string provider;
        std::string translation = FetchTranslation(
            request, provider_config_path_, &provider);
        if (request.target == "en" && translation == request.word) {
          translation.clear();
        }
        if (!translation.empty()) {
          // 先写入并刷新译文；音标由 Lua 在下一轮异步补查，不能阻塞首次显示。
          SaveTranslation(request, translation, "", provider);
          translation_saved = true;
          if (request.allow_online_fallback) {
            std::string phonetic;
            if (provider == "mac_dictionary") {
              phonetic = FetchMacDictionaryPhonetic(translation);
            }
            if (phonetic.empty()) phonetic = FetchPhonetic(translation);
            if (!phonetic.empty()) UpdatePhonetic(request, phonetic);
          }
        }
      }

      {
        std::lock_guard<std::mutex> lock(translation_mutex_);
        if (request.allow_online_fallback) {
          active_online_requests_.erase(request_key);
        }
        const bool upgrade_requested =
            online_upgrade_requests_.erase(request_key) > 0;
        if (!translation_saved && upgrade_requested && !request.emoji &&
            !request.speak_only) {
          request.allow_online_fallback = true;
          request.phonetic_only = false;
          translation_queue_.push_back(std::move(request));
          translation_wakeup_.notify_one();
          continue;
        }
        pending_requests_.erase(request_key);
      }
    }
  }

  std::string FetchEmojiName(const std::string& emoji) {
    static const char kScript[] =
        "import sys,unicodedata; "
        "print(', '.join(n for c in sys.argv[1] "
        "for n in [unicodedata.name(c, '')] if n))";
    std::string output;
    if (!RunCommand({"/usr/bin/python3", "-c", kScript, emoji}, &output)) {
      return {};
    }
    return CleanField(output);
  }

  void SaveTranslation(const TranslationRequest& request,
                       const std::string& translation,
                       const std::string& phonetic,
                       const std::string& provider) {
    std::lock_guard<std::mutex> lock(translation_mutex_);
    std::string key = CacheKey(request.target, request.word);
    auto found = cache_.find(key);
    if (found == cache_.end()) {
      cache_order_.push_back(key);
      found = cache_.emplace(key, CacheEntry{request.target, request.word,
                                             translation, phonetic, provider}).first;
    } else {
      found->second.translation = translation;
      found->second.phonetic = phonetic;
      found->second.provider = provider;
    }
    WriteCacheLocked();
    NotifyCacheChanged();
  }

  void UpdatePhonetic(const TranslationRequest& request,
                      const std::string& phonetic) {
    std::lock_guard<std::mutex> lock(translation_mutex_);
    auto found = cache_.find(CacheKey(request.target, request.word));
    if (found == cache_.end() || found->second.translation.empty()) return;
    found->second.phonetic = phonetic;
    WriteCacheLocked();
    NotifyCacheChanged();
  }

  void SaveEmojiCache(const std::string& emoji, const std::string& name) {
    std::ofstream file(emoji_cache_temp_path_);
    if (!file) return;
    std::ifstream old(emoji_cache_path_);
    std::vector<std::pair<std::string, std::string>> entries;
    std::string line;
    while (old && std::getline(old, line)) {
      std::vector<std::string> fields = SplitTabs(line);
      if (fields.size() >= 2 && !fields[0].empty() && !fields[1].empty()) {
        entries.emplace_back(fields[0], fields[1]);
      }
    }
    bool replaced = false;
    for (auto& entry : entries) {
      if (entry.first == emoji) {
        entry.second = name;
        replaced = true;
      }
    }
    if (!replaced) entries.emplace_back(emoji, name);
    size_t first = entries.size() > kCacheLimit
                       ? entries.size() - kCacheLimit
                       : 0;
    for (size_t index = first; index < entries.size(); ++index) {
      file << entries[index].first << '\t' << entries[index].second << '\n';
    }
    file.close();
    if (rename(emoji_cache_temp_path_.c_str(), emoji_cache_path_.c_str()) == 0) {
      NotifyCacheChanged();
    }
  }

  void WriteCacheLocked() {
    while (cache_order_.size() > kCacheLimit) {
      cache_.erase(cache_order_.front());
      cache_order_.pop_front();
    }
    std::ofstream file(cache_temp_path_);
    if (!file) return;
    for (const std::string& key : cache_order_) {
      auto found = cache_.find(key);
      if (found == cache_.end()) continue;
      const CacheEntry& entry = found->second;
      file << entry.target << '\t' << entry.word << '\t'
           << entry.translation;
      if (!entry.phonetic.empty() || !entry.provider.empty()) {
        file << '\t' << entry.phonetic;
        if (!entry.provider.empty()) file << '\t' << entry.provider;
      }
      file << '\n';
    }
    file.close();
    rename(cache_temp_path_.c_str(), cache_path_.c_str());
  }

  void WatchDirectory() {
    int directory = open(runtime_dir_.c_str(), O_EVTONLY | O_CLOEXEC);
    if (directory < 0) {
      running_.store(false);
      return;
    }

    int queue = kqueue();
    if (queue < 0) {
      close(directory);
      running_.store(false);
      return;
    }
    kqueue_fd_.store(queue);

    int request_file = open(request_path_.c_str(), O_RDONLY | O_CLOEXEC);
    int emoji_request_file =
        open(emoji_request_path_.c_str(), O_RDONLY | O_CLOEXEC);
    int speech_request_file =
        open(speech_request_path_.c_str(), O_RDONLY | O_CLOEXEC);
    // 请求文件是追加写入且长期保留；重启扩展时从当前文件尾开始，避免
    // 把上一次会话已经处理过的朗读请求重新加入队列。
    auto current_file_end = [](int descriptor) -> std::streamoff {
      if (descriptor < 0) return 0;
      off_t position = lseek(descriptor, 0, SEEK_END);
      return position < 0 ? 0 : static_cast<std::streamoff>(position);
    };
    request_offset_ = current_file_end(request_file);
    emoji_request_offset_ = current_file_end(emoji_request_file);
    speech_request_offset_ = current_file_end(speech_request_file);
    struct kevent changes[5] {};
    int change_count = 0;
    EV_SET(&changes[0], directory, EVFILT_VNODE, EV_ADD | EV_CLEAR,
           NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_RENAME | NOTE_DELETE,
           0, nullptr);
    change_count = 1;
    if (request_file >= 0) {
      EV_SET(&changes[change_count++], request_file, EVFILT_VNODE,
             EV_ADD | EV_CLEAR,
             NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_RENAME |
                 NOTE_DELETE,
             0, nullptr);
    }
    if (emoji_request_file >= 0) {
      EV_SET(&changes[change_count++], emoji_request_file, EVFILT_VNODE,
             EV_ADD | EV_CLEAR,
             NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_RENAME |
                 NOTE_DELETE,
                 0, nullptr);
    }
    if (speech_request_file >= 0) {
      EV_SET(&changes[change_count++], speech_request_file, EVFILT_VNODE,
             EV_ADD | EV_CLEAR,
             NOTE_WRITE | NOTE_EXTEND | NOTE_ATTRIB | NOTE_RENAME |
                 NOTE_DELETE,
             0, nullptr);
    }
    EV_SET(&changes[change_count++], kStopEvent, EVFILT_USER,
           EV_ADD | EV_CLEAR, 0, 0,
           nullptr);
    if (kevent(queue, changes, change_count, nullptr, 0, nullptr) != 0) {
      kqueue_fd_.store(-1);
      if (request_file >= 0) close(request_file);
      if (emoji_request_file >= 0) close(emoji_request_file);
      if (speech_request_file >= 0) close(speech_request_file);
      close(queue);
      close(directory);
      running_.store(false);
      return;
    }

    FileSignature cache_signature = ReadSignature(cache_path_);
    FileSignature emoji_signature = ReadSignature(emoji_cache_path_);
    ReadTranslationRequests();

    while (running_.load()) {
      struct kevent event {};
      int count = kevent(queue, nullptr, 0, &event, 1, nullptr);
      if (count < 0) {
        if (errno == EINTR) {
          continue;
        }
        break;
      }
      if (count == 0 ||
          (event.filter == EVFILT_USER && event.ident == kStopEvent)) {
        continue;
      }

      ReadTranslationRequests();

      FileSignature next_cache = ReadSignature(cache_path_);
      FileSignature next_emoji = ReadSignature(emoji_cache_path_);
      bool changed = next_cache != cache_signature ||
                     next_emoji != emoji_signature;
      for (int attempt = 0; !changed && attempt < 4; ++attempt) {
        if (access(cache_temp_path_.c_str(), F_OK) != 0 &&
            access(emoji_cache_temp_path_.c_str(), F_OK) != 0) {
          break;
        }
        usleep(25000);
        next_cache = ReadSignature(cache_path_);
        next_emoji = ReadSignature(emoji_cache_path_);
        changed = next_cache != cache_signature ||
                  next_emoji != emoji_signature;
      }
      cache_signature = next_cache;
      emoji_signature = next_emoji;
      if (changed) {
        NotifyCacheChanged();
      }

      if (event.ident == static_cast<uintptr_t>(directory) &&
          (event.fflags & (NOTE_DELETE | NOTE_RENAME)) != 0) {
        break;
      }
    }

    kqueue_fd_.store(-1);
    if (request_file >= 0) close(request_file);
    if (emoji_request_file >= 0) close(emoji_request_file);
    if (speech_request_file >= 0) close(speech_request_file);
    close(queue);
    close(directory);
  }

  void NotifyCacheChanged() {
    refresh_generation_.fetch_add(1);
    ScheduleDispatch();
  }

  void ScheduleDispatch() {
    bool expected = false;
    if (!running_.load() ||
        !dispatch_pending_.compare_exchange_strong(expected, true)) {
      return;
    }
    auto* task = new DispatchTask{this, lifecycle_.load()};
    dispatch_async_f(dispatch_get_main_queue(), task, RunDispatch);
  }

  static void RunDispatch(void* value) {
    std::unique_ptr<DispatchTask> task(static_cast<DispatchTask*>(value));
    task->manager->RefreshOnMain(task->lifecycle);
  }

  void RefreshOnMain(uint64_t task_lifecycle) {
    if (!running_.load() || task_lifecycle != lifecycle_.load()) {
      return;
    }

    uint64_t observed_generation = refresh_generation_.load();
    std::vector<std::shared_ptr<ContextRegistration>> active;
    {
      std::lock_guard<std::mutex> lock(registrations_mutex_);
      auto output = registrations_.begin();
      for (auto item = registrations_.begin(); item != registrations_.end();
           ++item) {
        auto registration = item->lock();
        if (registration && registration->alive.load()) {
          active.push_back(registration);
          *output++ = *item;
        }
      }
      registrations_.erase(output, registrations_.end());
    }

    std::string value = std::to_string(observed_generation);
    for (const auto& registration : active) {
      if (registration->alive.load() && registration->context &&
          registration->context->IsComposing()) {
        size_t selected_index = 0;
        if (!registration->context->composition().empty()) {
          selected_index = registration->context->composition().back().selected_index;
        }
        const std::string remembered_index = registration->context->get_property(
            kSelectedCandidateIndexProperty);
        if (!remembered_index.empty()) {
          char* end = nullptr;
          const unsigned long parsed =
              std::strtoul(remembered_index.c_str(), &end, 10);
          if (end != remembered_index.c_str() && *end == '\0') {
            selected_index = static_cast<size_t>(parsed);
          }
        }
        std::string selected_text;
        if (auto selected = registration->context->GetSelectedCandidate()) {
          selected_text = selected->text();
        }
        const std::string remembered = registration->context->get_property(
            kSelectedCandidateProperty);
        if (!remembered.empty()) selected_text = remembered;
        // RefreshNonConfirmedComposition 可能重建组合并将选中项归零；
        // 仅在这次重算期间临时保存当前候选，避免覆盖鼠标的新选择。
        registration->context->set_property(kRefreshSelectionProperty,
                                             selected_text);
        // 先让 Rime 重算未确认组合，使 Lua filter 重新读取刚写入的缓存；
        // _refresh_ui 本身只刷新前端，不会重新执行候选生成链。
        registration->context->RefreshNonConfirmedComposition();
        registration->context->set_property(kRefreshSelectionProperty, "");
        // 异步缓存刷新也会把新建 menu 的索引归零；在通知前恢复索引，
        // 让鼠须管读取到的 highlighted_candidate_index 与当前候选一致。
        if (!registration->context->composition().empty() &&
            registration->context->composition().back().menu) {
          auto& segment = registration->context->composition().back();
          const size_t count = segment.menu->Prepare(selected_index + 1);
          if (selected_index < count) {
            segment.selected_index = selected_index;
            segment.tags.insert("paging");
          }
        }
        registration->context->set_property(kRefreshProperty, value);
      }
    }

    dispatch_pending_.store(false);
    if (running_.load() && task_lifecycle == lifecycle_.load() &&
        refresh_generation_.load() != observed_generation) {
      ScheduleDispatch();
    }
  }

  std::atomic<bool> running_{false};
  std::atomic<bool> dispatch_pending_{false};
  std::atomic<int> kqueue_fd_{-1};
  std::atomic<uint64_t> lifecycle_{0};
  std::atomic<uint64_t> refresh_generation_{0};
  std::thread worker_;
  std::string user_dir_;
  std::string runtime_dir_;
  std::string cache_path_;
  std::string emoji_cache_path_;
  std::string cache_temp_path_;
  std::string emoji_cache_temp_path_;
  std::string request_path_;
  std::string emoji_request_path_;
  std::string speech_request_path_;
  std::string provider_config_path_;
  std::streamoff request_offset_ = 0;
  std::streamoff emoji_request_offset_ = 0;
  std::streamoff speech_request_offset_ = 0;
  std::mutex translation_mutex_;
  std::condition_variable translation_wakeup_;
  std::deque<TranslationRequest> translation_queue_;
  std::set<std::string> pending_requests_;
  std::set<std::string> active_online_requests_;
  std::set<std::string> online_upgrade_requests_;
  std::map<std::string, CacheEntry> cache_;
  std::deque<std::string> cache_order_;
  std::vector<std::thread> translation_workers_;
  std::mutex registrations_mutex_;
  std::vector<std::weak_ptr<ContextRegistration>> registrations_;
};

class TranslationRefreshProcessor : public rime::Processor {
 public:
  explicit TranslationRefreshProcessor(const rime::Ticket& ticket)
      : rime::Processor(ticket),
        registration_(
            RefreshManager::Instance().Register(engine_->context())) {}

  ~TranslationRefreshProcessor() override {
    RefreshManager::Instance().Unregister(registration_);
  }

  rime::ProcessResult ProcessKeyEvent(const rime::KeyEvent& key_event) override {
    if (HandleCandidateArrow(key_event)) return rime::kAccepted;
    ClearRememberedSelection(key_event);
    return rime::kNoop;
  }

 private:
  void ClearRememberedSelection(const rime::KeyEvent& key_event) {
    if (key_event.release() || key_event.alt() || key_event.super()) return;
    rime::Context* context = engine_->context();
    if (context) {
      if (!context->get_property(kSelectedCandidateProperty).empty()) {
        context->set_property(kSelectedCandidateProperty, "");
      }
      if (!context->get_property(kSelectedCandidateIndexProperty).empty()) {
        context->set_property(kSelectedCandidateIndexProperty, "");
      }
    }
  }

  bool HandleCandidateArrow(const rime::KeyEvent& key_event) {
    if (key_event.release() || key_event.alt() || key_event.super()) return false;
    rime::Context* context = engine_->context();
    if (!context || context->composition().empty() || !context->HasMenu()) {
      return false;
    }

    const bool vertical = context->get_option("_vertical");
    const bool linear = context->get_option("_linear") ||
                        context->get_option("_horizontal");
    const bool at_end = context->caret_pos() >= context->input().length();
    if (linear && !at_end) return false;

    int direction = 0;
    const int keycode = key_event.keycode();
    if (!vertical && !linear) {
      if (keycode == XK_Up || keycode == XK_KP_Up) direction = -1;
      if (keycode == XK_Down || keycode == XK_KP_Down) direction = 1;
    } else if (!vertical && linear) {
      if (keycode == XK_Left || keycode == XK_KP_Left) direction = -1;
      if (keycode == XK_Right || keycode == XK_KP_Right) direction = 1;
    } else if (vertical && !linear) {
      if (keycode == XK_Right || keycode == XK_KP_Right) direction = -1;
      if (keycode == XK_Left || keycode == XK_KP_Left) direction = 1;
    } else {
      if (keycode == XK_Up || keycode == XK_KP_Up) direction = -1;
      if (keycode == XK_Down || keycode == XK_KP_Down) direction = 1;
    }
    if (direction == 0 || key_event.ctrl()) return false;

    rime::Segment& segment = context->composition().back();
    size_t current = segment.selected_index;
    const std::string remembered_index =
        context->get_property(kSelectedCandidateIndexProperty);
    if (!remembered_index.empty()) {
      char* end = nullptr;
      const unsigned long parsed = std::strtoul(remembered_index.c_str(), &end, 10);
      if (end != remembered_index.c_str() && *end == '\0') {
        current = static_cast<size_t>(parsed);
      }
    }
    const size_t available = segment.menu->Prepare(current + 1);
    if (available == 0 || current >= available) {
      current = segment.selected_index;
    }
    size_t target = current;
    if (direction < 0) {
      if (current == 0) return true;
      target = current - 1;
    } else {
      const size_t count = segment.menu->Prepare(current + 2);
      if (current + 1 >= count) return true;
      target = current + 1;
    }
    auto candidate = segment.menu->GetCandidateAt(target);
    if (!candidate) return true;

    // 先让 Lua filter 重新执行，再恢复原生高亮。
    // Rime 的 Highlight() 只更新 selected_index，不会重跑已经建立的
    // menu filter；而 RefreshNonConfirmedComposition() 会重建 menu 但把
    // selected_index 归零，因此两步必须按这个顺序完成。
    context->set_property(kSelectedCandidateProperty, candidate->text());
    context->set_property(kSelectedCandidateIndexProperty,
                          std::to_string(target));
    context->set_property(kRefreshSelectionProperty, candidate->text());
    context->RefreshNonConfirmedComposition();
    if (context->composition().empty() || !context->composition().back().menu) {
      context->set_property(kRefreshSelectionProperty, "");
      return true;
    }
    context->composition().back().tags.insert("paging");
    context->Highlight(target);
    // Highlight() 会同步触发 update_notifier；在鼠须管随后读取候选菜单
    // 前再写回一次，防止重算链把当前索引恢复为 0。
    if (!context->composition().empty()) {
      context->composition().back().selected_index = target;
    }
    context->set_property(kRefreshSelectionProperty, "");
    return true;
  }

  std::shared_ptr<ContextRegistration> registration_;
};

}  // namespace

static void rime_translation_refresh_initialize() {
  RefreshManager::Instance().Start();
  rime::Registry::instance().Register(
      kComponentName, new rime::Component<TranslationRefreshProcessor>);
}

static void rime_translation_refresh_finalize() {
  RefreshManager::Instance().Stop();
  DeepLWebClient::Instance().Stop();
}

RIME_REGISTER_MODULE(translation_refresh)
