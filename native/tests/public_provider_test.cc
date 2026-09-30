#include "../src/json_string.h"

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
}
