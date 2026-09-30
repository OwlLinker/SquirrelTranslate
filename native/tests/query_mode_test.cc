// No Rime initialization, dictionaries, user configuration, or system hooks.
// Exercise only the registry of live contexts that the read-only IPC queries.
#include "../src/translation_refresh.cc"
#include <cassert>

int main() {
  assert(CacheKey("en", "abc") != CacheKey("e", "nabc"));
  assert(CacheKey("en", "word") == std::string("en\0word", 7));

  std::string decoded;
  size_t decoded_end = 0;
  assert(squirrel_translate_json::ParseStringAt(
      "\"a\\n\\u4f60\\ud83d\\ude80\"", 0, &decoded,
      &decoded_end));
  assert(decoded == "a\n你🚀");
  assert(decoded_end == std::string("\"a\\n\\u4f60\\ud83d\\ude80\"").size());
  assert(!squirrel_translate_json::ParseStringAt(
      "\"\\ud83d\"", 0, &decoded, &decoded_end));

  auto& manager = RefreshManager::Instance();
  rime::Context first;
  first.set_property("client_app", "org.example.Host");
  auto one = manager.Register(&first);
  one->client_pid = 123;
  assert(manager.ReadQueryMode("org.example.Unknown", 123) == -1);
  assert(manager.ReadQueryMode("org.example.Host", 123) == 0);
  first.set_option("ascii_mode", true);
  assert(manager.ReadQueryMode("org.example.Host", 123) == 1);

  rime::Context second;
  second.set_property("client_app", "org.example.Host");
  auto two = manager.Register(&second);
  two->client_pid = 123;
  assert(manager.ReadQueryMode("org.example.Host", 456) == -1);
  assert(manager.ReadQueryMode("org.example.Host", 123) == -1);
  manager.NoteQueryActivity(one);
  assert(manager.ReadQueryMode("org.example.Host", 123) == 1);
  manager.NoteQueryActivity(two);
  assert(manager.ReadQueryMode("org.example.Host", 123) == 0);
  second.set_option("ascii_mode", true);
  assert(manager.ReadQueryMode("org.example.Host", 123) == 1);
  manager.Unregister(two);
  manager.Unregister(one);
  assert(manager.ReadQueryMode("org.example.Host", 123) == -1);
  puts("PASS: exact application matching, Chinese/English changes, unknown and ambiguous sessions, last active session, deleted contexts");
}
