#include "dict.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int contains(const dict_buffer *buffer, const char *needle) {
    if (buffer->data == NULL) return 0;
    const size_t n = strlen(needle);
    if (n == 0 || n > buffer->len) return 0;
    for (size_t i = 0; i + n <= buffer->len; ++i)
        if (memcmp(buffer->data + i, needle, n) == 0) return 1;
    return 0;
}

static int require(int condition, const char *label) {
    if (condition) return 1;
    fprintf(stderr, "FFI assertion failed: %s\n", label);
    return 0;
}

static int lookup(dict_handle *handle, const char *word, const char *required) {
    dict_buffer result = {0};
    const dict_status status = dict_lookup_json(handle, word, strlen(word), &result);
    const int ok = require(status == DICT_OK, word) && require(contains(&result, required), required);
    dict_buffer_free(handle, &result);
    return ok;
}

static int validate_records(void) {
    dict_handle *worker = NULL;
    // Opening a validation handle does not need an existing readable dataset.
    const char *unopened = ".tmp/not-a-readable-dictionary";
    if (!require(dict_open(unopened, strlen(unopened), &worker) == DICT_OK, "open independent validation worker")) return 0;
    uint8_t header[] = {'W','I','K','B','L','B','0','8', 3};
    uint8_t empty[32] = {'D','P','R','2'};
    int ok = 1;
    for (uint8_t kind = 2; kind <= 7; ++kind) {
        header[8] = kind;
        ok &= require(dict_validate_record(worker, header, sizeof header, "entry", 5, empty, sizeof empty) == DICT_OK, "empty feature full semantic validation");
    }
    const uint8_t language[] = "WIKBLB08\x01" "en\0English\0";
    ok &= require(dict_validate_record(worker, language, sizeof language - 1, "entry", 5, empty, sizeof empty) == DICT_OK, "language header supplies actual semantic context");
    ok &= require(dict_validate_record(worker, header, sizeof header, "entry", 5, empty, 4) != DICT_OK, "bare DPR2 refused");
    size_t length = 0;
    const char *error = dict_last_error(worker, &length);
    ok &= require(error != NULL && length != 0, "worker owns validation diagnostic");
    ok &= require(dict_validate_record(worker, NULL, 9, "entry", 5, empty, sizeof empty) == DICT_INVALID_ARGUMENT, "null binary header refused");
    ok &= require(dict_validate_record(worker, header, sizeof header, "entry", 5, NULL, 32) == DICT_INVALID_ARGUMENT, "null binary payload refused");
    ok &= require(dict_validate_record(worker, header, sizeof header, "bad\0title", 9, empty, sizeof empty) == DICT_INVALID_ARGUMENT, "NUL title refused");
    ok &= require(dict_validate_record(worker, header, sizeof header, "entry", 5, empty, sizeof empty) == DICT_OK, "validation recovers after failure");
    dict_last_error(worker, &length);
    ok &= require(length == 0, "successful validation clears worker error");
    dict_close(worker);
    return ok;
}

int main(int argc, char **argv) {
    if (argc < 2 || argc > 4 || (argc == 4 && strcmp(argv[3], "--neutral") != 0)) {
        fprintf(stderr, "usage: ffi-integration ROOT [WORD [--neutral]]\n");
        return 2;
    }
    if (!validate_records()) return 1;
    const int neutral = argc == 4;
    const char *word = argc >= 3 ? argv[2] : "mouse";
    dict_handle *handle = NULL;
    dict_status status = dict_open(argv[1], strlen(argv[1]), &handle);
    if (!require(status == DICT_OK && handle != NULL, "open")) return 1;
    if (!require(DICT_ABI_VERSION == 4u && dict_abi_version() == DICT_ABI_VERSION, "ABI version")) return 1;
    if (neutral) {
        int ok = require(dict_select(handle, NULL, 0, "language", 8) == DICT_OK, "neutral selection without language");
        dict_buffer result = {0};
        status = dict_lookup_json(handle, word, strlen(word), &result);
        ok &= require(status == DICT_OK && contains(&result, "\"language\": null"), "neutral language null");
        ok &= require(contains(&result, "\"title\": \"ChainB\"") && contains(&result, "\"source_title\": \"ChainA\""), "neutral one-hop provenance");
        ok &= require(contains(&result, "\"target_title\": \"gainst\""), "displayed redirect next target");
        dict_buffer_free(handle, &result);
        status = dict_languages_json(handle, &result);
        ok &= require(status == DICT_OK && contains(&result, "\"languages\": []"), "no fabricated language menu");
        dict_buffer_free(handle, &result);
        status = dict_search_json(handle, "Ch", 2, 10, 0, &result);
        ok &= require(status == DICT_OK && contains(&result, "ChainA") && !contains(&result, "1\\t"), "human alias search titles");
        dict_buffer_free(handle, &result);
        ok &= require(dict_select(handle, NULL, 0, "alias", 5) == DICT_INVALID_ARGUMENT, "alias is internal");
        ok &= lookup(handle, "Animus", "\"followed\": false");
        dict_close(handle);
        if (!ok) return 1;
        puts("FFI_NEUTRAL_PASS: null language, one-hop redirects, no language menu fabrication");
        return 0;
    }
    if (!require(dict_select(handle, NULL, 0, "language", 8) == DICT_INVALID_ARGUMENT, "ordinary empty language stays invalid")) return 1;
    status = dict_select(handle, "English", 7, "language", 8);
    if (!require(status == DICT_OK, "select English")) return 1;

    int ok = 1;
    ok &= lookup(handle, word, word);

    dict_buffer stats = {0};
    status = dict_stats_json(handle, &stats);
    ok &= require(status == DICT_OK, "stats") && require(contains(&stats, "\"records\""), "record stats");
    dict_buffer_free(handle, &stats);

    dict_buffer search = {0};
    const size_t prefix_len = strlen(word) < 2 ? strlen(word) : 2;
    status = dict_search_json(handle, word, prefix_len, 10, 0, &search);
    ok &= require(status == DICT_OK, "search") && require(contains(&search, word), "search word");
    dict_buffer_free(handle, &search);

    dict_buffer languages = {0};
    status = dict_languages_json(handle, &languages);
    ok &= require(status == DICT_OK, "languages") && require(contains(&languages, "English"), "English language");
    dict_buffer_free(handle, &languages);

    dict_buffer random = {0};
    status = dict_random_json(handle, &random);
    ok &= require(status == DICT_OK, "random") && require(contains(&random, "\"entries\""), "random entry");
    dict_buffer_free(handle, &random);

    dict_close(handle);
    if (!ok) return 1;
    puts("FFI_INTEGRATION_PASS: data-only C ABI, lookup/search/random/languages/stats");
    return 0;
}
