#include "../src/json_string.h"
#include "../src/public_translation_providers.h"

#include <cassert>
#include <string>

int main() {
  std::string decoded;
  size_t end = 0;
  const std::string encoded = "\"a\\n\\u4f60\\ud83d\\ude80\"";
  assert(squirrel_translate_json::ParseStringAt(encoded, 0, &decoded, &end));
  assert(decoded == "a\n你🚀");
  assert(end == encoded.size());
  assert(!squirrel_translate_json::ParseStringAt(
      "\"\\ud83d\"", 0, &decoded, &end));
  assert(!squirrel_translate_json::ParseStringAt(
      "\"raw\nnewline\"", 0, &decoded, &end));

  const std::string color_phonetic =
      squirrel_translate_public::FetchMacDictionaryPhonetic("color");
  assert(squirrel_translate_public::FetchMacDictionaryPhonetic(
      "color; colour") == color_phonetic);
  const squirrel_translate_public::Request request{"test", "en"};
  const std::string source_path = __FILE__;
  const std::string fixture = "file://" + source_path.substr(
      0, source_path.find_last_of('/')) + "/deepl_response.json";
  const squirrel_translate_public::ProviderConfig local_endpoint{
      fixture, "TEST_ONLY"};
  assert(squirrel_translate_public::Fetch("deepl", request,
                                          local_endpoint) == "stdin verified");
  const squirrel_translate_public::ProviderConfig invalid_header{
      fixture, "TEST_ONLY\nInjected: header"};
  assert(squirrel_translate_public::Fetch("deepl", request,
                                          invalid_header).empty());
}
