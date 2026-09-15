#ifndef DICT_FFI_H
#define DICT_FFI_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct dict_handle dict_handle;
typedef struct dict_buffer {
    uint8_t *data;
    size_t len;
} dict_buffer;

typedef enum dict_status {
    DICT_OK = 0,
    DICT_NOT_FOUND = 1,
    DICT_INVALID_ARGUMENT = 2,
    DICT_IO_ERROR = 3,
    DICT_OUT_OF_MEMORY = 4,
    DICT_INTERNAL_ERROR = 5
} dict_status;

uint32_t dict_abi_version(void);

dict_status dict_open(
    const char *root, size_t root_len,
    dict_handle **out_handle);
void dict_close(dict_handle *handle);

dict_status dict_select(
    dict_handle *handle,
    const char *language, size_t language_len,
    const char *kind, size_t kind_len);

dict_status dict_search_json(
    dict_handle *handle,
    const char *query, size_t query_len,
    size_t limit, size_t offset,
    dict_buffer *out);
dict_status dict_lookup_json(
    dict_handle *handle,
    const char *query, size_t query_len,
    dict_buffer *out);
dict_status dict_random_json(dict_handle *handle, dict_buffer *out);
dict_status dict_languages_json(dict_handle *handle, dict_buffer *out);
dict_status dict_stats_json(dict_handle *handle, dict_buffer *out);
void dict_buffer_free(dict_handle *handle, dict_buffer *buffer);
const char *dict_last_error(const dict_handle *handle, size_t *out_len);
const char *dict_status_name(dict_status status);

#ifdef __cplusplus
}
#endif

#endif
