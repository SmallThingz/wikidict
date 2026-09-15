#include "dict.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int contains(const dict_buffer *buffer, const char *needle) {
    if (buffer->data == NULL) return 0;
    const size_t n = strlen(needle);
    if (n == 0 || n > buffer->len) return 0;
    for (size_t i = 0; i + n <= buffer->len; ++i) {
        if (memcmp(buffer->data + i, needle, n) == 0) return 1;
    }
    return 0;
}

static int require(int condition, const char *label) {
    if (condition) return 1;
    fprintf(stderr, "FFI assertion failed: %s\n", label);
    return 0;
}

static int call_lookup(dict_handle *handle, const char *word, uint32_t flags,
                       const char *required) {
    dict_buffer result = {0};
    const dict_status status = dict_lookup_json(handle, word, strlen(word), flags, &result);
    const int ok = require(status == DICT_OK, word) && require(contains(&result, required), required);
    dict_buffer_free(handle, &result);
    return ok;
}
static int stats(dict_handle *handle, const char *starts, const char *requests) {
    dict_buffer result = {0};
    const dict_status status = dict_stats_json(handle, &result);
    const int ok = require(status == DICT_OK, "stats") &&
                   require(contains(&result, starts), starts) &&
                   require(contains(&result, requests), requests);
    dict_buffer_free(handle, &result);
    return ok;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: ffi-integration ROOT\n");
        return 2;
    }
    dict_handle *handle = NULL;
    dict_status status = dict_open(argv[1], strlen(argv[1]), &handle);
    if (!require(status == DICT_OK && handle != NULL, "open")) return 1;
    if (!require(dict_abi_version() == 1, "ABI version")) return 1;
    status = dict_select(handle, "English", 7, "language", 8);
    if (!require(status == DICT_OK, "select English")) return 1;
    status = dict_set_runtime_timeout(handle, 200);
    if (!require(status == DICT_OK, "set timeout")) return 1;

    int ok = 1;
    ok &= call_lookup(handle, "mouse", DICT_LOOKUP_WITH_SOURCE, "\"status\": \"ok\"");
    ok &= stats(handle, "\"lua_worker_starts\": 1", "\"lua_requests\": 1");
    ok &= call_lookup(handle, "mouse", 0, "Forms from native Lua");
    ok &= stats(handle, "\"lua_worker_starts\": 1", "\"lua_requests\": 2");
    ok &= call_lookup(handle, "badcall", 0, "NotCallable");
    ok &= call_lookup(handle, "loop", 0, "timed out");
    ok &= call_lookup(handle, "mouse", 0, "Forms from native Lua");
    ok &= stats(handle, "\"lua_worker_starts\": 2", "\"lua_requests\": 5");

    dict_buffer search = {0};
    status = dict_search_json(handle, "mo", 2, 10, 0, &search);
    ok &= require(status == DICT_OK, "search") && require(contains(&search, "mouse"), "search mouse");
    dict_buffer_free(handle, &search);

    dict_buffer languages = {0};
    status = dict_languages_json(handle, &languages);
    ok &= require(status == DICT_OK, "languages") && require(contains(&languages, "English"), "English language");
    dict_buffer_free(handle, &languages);

    dict_buffer random = {0};
    status = dict_random_json(handle, 0, &random);
    ok &= require(status == DICT_OK, "random") && require(contains(&random, "\"entries\""), "random entry");
    dict_buffer_free(handle, &random);

    dict_close(handle);
    if (!ok) return 1;
    puts("FFI_INTEGRATION_PASS: stable C ABI, persistent worker reuse/restart, search, random, languages");
    return 0;
}
