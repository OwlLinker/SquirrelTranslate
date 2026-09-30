#pragma once

#include <atomic>
#include <cstddef>
#include <cstdint>
#include <string>

namespace squirrel_translate_public {

struct Request {
  std::string word;
  std::string target;
  const std::atomic<uint64_t>* generation_source = nullptr;
  uint64_t generation = 0;
};

struct ProviderConfig {
  std::string endpoint;
  std::string api_key;
};

std::string FetchMacDictionaryAt(const Request& request,
                                 std::size_t dictionary_index);
std::string FetchMacDictionaryDefault(const Request& request);

// Public provider set: macOS Dictionary, Google, Bing and DeepL API.
// Returns an empty string when the provider has no result or is unavailable.
std::string Fetch(const std::string& provider, const Request& request,
                  const ProviderConfig& config);

}  // namespace squirrel_translate_public
