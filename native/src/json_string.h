#pragma once

#include <cstddef>
#include <string>

namespace squirrel_translate_json {

inline int HexValue(char digit) {
  if (digit >= '0' && digit <= '9') return digit - '0';
  if (digit >= 'a' && digit <= 'f') return digit - 'a' + 10;
  if (digit >= 'A' && digit <= 'F') return digit - 'A' + 10;
  return -1;
}

inline bool ReadCodeUnit(const std::string& json, size_t position,
                         unsigned int* value) {
  if (position + 4 > json.size()) return false;
  unsigned int result = 0;
  for (size_t offset = 0; offset < 4; ++offset) {
    const int digit = HexValue(json[position + offset]);
    if (digit < 0) return false;
    result = (result << 4) | static_cast<unsigned int>(digit);
  }
  *value = result;
  return true;
}

inline void AppendUTF8(unsigned int codepoint, std::string* output) {
  if (codepoint <= 0x7f) {
    output->push_back(static_cast<char>(codepoint));
  } else if (codepoint <= 0x7ff) {
    output->push_back(static_cast<char>(0xc0 | (codepoint >> 6)));
    output->push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  } else if (codepoint <= 0xffff) {
    output->push_back(static_cast<char>(0xe0 | (codepoint >> 12)));
    output->push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
    output->push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  } else {
    output->push_back(static_cast<char>(0xf0 | (codepoint >> 18)));
    output->push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f)));
    output->push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
    output->push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
  }
}

inline bool ParseStringAt(const std::string& json, size_t start,
                          std::string* value, size_t* end_position) {
  if (!value || !end_position || start >= json.size() || json[start] != '"')
    return false;

  std::string result;
  for (size_t index = start + 1; index < json.size(); ++index) {
    const unsigned char character = static_cast<unsigned char>(json[index]);
    if (character == '"') {
      *value = result;
      *end_position = index + 1;
      return true;
    }
    if (character < 0x20) return false;
    if (character != '\\') {
      result.push_back(static_cast<char>(character));
      continue;
    }
    if (++index >= json.size()) return false;
    switch (json[index]) {
      case '"': result.push_back('"'); break;
      case '\\': result.push_back('\\'); break;
      case '/': result.push_back('/'); break;
      case 'b': result.push_back('\b'); break;
      case 'f': result.push_back('\f'); break;
      case 'n': result.push_back('\n'); break;
      case 'r': result.push_back('\r'); break;
      case 't': result.push_back('\t'); break;
      case 'u': {
        unsigned int codepoint = 0;
        if (!ReadCodeUnit(json, index + 1, &codepoint)) return false;
        index += 4;
        if (codepoint >= 0xd800 && codepoint <= 0xdbff) {
          if (index + 6 >= json.size() || json[index + 1] != '\\' ||
              json[index + 2] != 'u') return false;
          unsigned int low = 0;
          if (!ReadCodeUnit(json, index + 3, &low) ||
              low < 0xdc00 || low > 0xdfff) return false;
          codepoint = 0x10000 + ((codepoint - 0xd800) << 10) +
                      (low - 0xdc00);
          index += 6;
        } else if (codepoint >= 0xdc00 && codepoint <= 0xdfff) {
          return false;
        }
        AppendUTF8(codepoint, &result);
        break;
      }
      default: return false;
    }
  }
  return false;
}

}  // namespace squirrel_translate_json
