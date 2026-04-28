/*
  ollama_embed.cc — MySQL UDF that calls a local Ollama embedding model
  and returns the result as a MySQL-native VECTOR binary blob.

  Supported MySQL version: 8.0.45 Commercial (Enterprise Edition)
  Ollama model: qwen3-embedding:0.6b (896-dimensional output)

  Build: see CMakeLists.txt
  Install: INSTALL PLUGIN / CREATE FUNCTION … SONAME 'ollama_embed.so'
*/

#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <cstdint>
#include <vector>
#include <string>

#include <curl/curl.h>
#include "cJSON.h"

// MySQL UDF API header — installed with the MySQL development package.
// Typical paths:
//   /usr/include/mysql/mysql.h  (community)
//   /usr/include/mysql/udf_registration_types.h
// The cmake build passes -DMYSQL_INCLUDE_DIR=<path> so the compiler
// can find mysql.h which pulls in mysql_com.h and the UDF API types.
#include <mysql.h>

// --------------------------------------------------------------------------
// Constants
// --------------------------------------------------------------------------
static const char  OLLAMA_URL[]  = "http://localhost:11434/api/embeddings";
static const char  OLLAMA_MODEL[] = "qwen3-embedding:0.6b";
static const int   EXPECTED_DIMS  = 896;
static const long  CURL_TIMEOUT_S = 30L;

// --------------------------------------------------------------------------
// libcurl write callback — appends received data into a std::string
// --------------------------------------------------------------------------
struct WriteBuffer {
    std::string data;
};

static size_t curl_write_cb(char *ptr, size_t size, size_t nmemb, void *userdata)
{
    size_t total = size * nmemb;
    auto *buf = static_cast<WriteBuffer *>(userdata);
    buf->data.append(ptr, total);
    return total;
}

// --------------------------------------------------------------------------
// Helper: call Ollama and return the embedding as a vector of floats.
// On error, returns an empty vector and sets errmsg.
// --------------------------------------------------------------------------
static std::vector<float> fetch_embedding(const char *text,
                                          char       *errmsg,
                                          size_t      errmsg_size)
{
    std::vector<float> result;

    // Build JSON request body
    cJSON *root = cJSON_CreateObject();
    if (!root) {
        snprintf(errmsg, errmsg_size, "ollama_embed: cJSON_CreateObject failed");
        return result;
    }
    cJSON_AddStringToObject(root, "model", OLLAMA_MODEL);
    cJSON_AddStringToObject(root, "prompt", text);
    char *request_body = cJSON_PrintUnformatted(root);
    cJSON_Delete(root);
    if (!request_body) {
        snprintf(errmsg, errmsg_size, "ollama_embed: cJSON_PrintUnformatted failed");
        return result;
    }

    // Initialise libcurl
    CURL *curl = curl_easy_init();
    if (!curl) {
        free(request_body);
        snprintf(errmsg, errmsg_size, "ollama_embed: curl_easy_init failed");
        return result;
    }

    WriteBuffer response;
    struct curl_slist *headers = nullptr;
    headers = curl_slist_append(headers, "Content-Type: application/json");

    curl_easy_setopt(curl, CURLOPT_URL,            OLLAMA_URL);
    curl_easy_setopt(curl, CURLOPT_POST,           1L);
    curl_easy_setopt(curl, CURLOPT_POSTFIELDS,     request_body);
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER,     headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION,  curl_write_cb);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA,      &response);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT,        CURL_TIMEOUT_S);
    // Do not verify SSL — local plaintext HTTP, but be explicit
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYPEER, 0L);
    curl_easy_setopt(curl, CURLOPT_SSL_VERIFYHOST, 0L);

    CURLcode rc = curl_easy_perform(curl);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);
    free(request_body);

    if (rc != CURLE_OK) {
        snprintf(errmsg, errmsg_size,
                 "ollama_embed: HTTP request failed: %s",
                 curl_easy_strerror(rc));
        return result;
    }

    // Parse JSON response:  {"embedding": [f1, f2, ...]}
    cJSON *json = cJSON_Parse(response.data.c_str());
    if (!json) {
        snprintf(errmsg, errmsg_size,
                 "ollama_embed: failed to parse Ollama response as JSON");
        return result;
    }

    cJSON *embedding_arr = cJSON_GetObjectItemCaseSensitive(json, "embedding");
    if (!cJSON_IsArray(embedding_arr)) {
        const char *err = cJSON_GetErrorPtr();
        snprintf(errmsg, errmsg_size,
                 "ollama_embed: 'embedding' array not found in response%s%s",
                 err ? "; parse error near: " : "",
                 err ? err : "");
        cJSON_Delete(json);
        return result;
    }

    int dim = cJSON_GetArraySize(embedding_arr);
    result.reserve(static_cast<size_t>(dim));

    cJSON *item = nullptr;
    cJSON_ArrayForEach(item, embedding_arr) {
        if (!cJSON_IsNumber(item)) {
            snprintf(errmsg, errmsg_size,
                     "ollama_embed: non-numeric value in embedding array");
            cJSON_Delete(json);
            result.clear();
            return result;
        }
        result.push_back(static_cast<float>(item->valuedouble));
    }

    cJSON_Delete(json);
    return result;
}

// --------------------------------------------------------------------------
// MySQL UDF entry points
// All three must be exported with C linkage.
// --------------------------------------------------------------------------
extern "C" {

// ------------------------------------------------------------------
// ollama_embed_init
//   Called once per query to validate arguments and set metadata.
// ------------------------------------------------------------------
my_bool ollama_embed_init(UDF_INIT *initid, UDF_ARGS *args, char *message)
{
    if (args->arg_count != 1) {
        strncpy(message,
                "ollama_embed() requires exactly one string argument",
                MYSQL_ERRMSG_SIZE - 1);
        message[MYSQL_ERRMSG_SIZE - 1] = '\0';
        return 1;
    }

    // Coerce the argument to STRING so MySQL converts non-string types for us
    args->arg_type[0] = STRING_RESULT;

    // Return type is STRING (binary blob carrying the packed floats)
    initid->max_length  = static_cast<unsigned long>(EXPECTED_DIMS * sizeof(float));
    initid->maybe_null  = 1;  // we may return NULL on error
    initid->const_item  = 0;

    // We'll allocate the result buffer once and reuse it
    initid->ptr = static_cast<char *>(malloc(initid->max_length));
    if (!initid->ptr) {
        strncpy(message,
                "ollama_embed: failed to allocate result buffer",
                MYSQL_ERRMSG_SIZE - 1);
        message[MYSQL_ERRMSG_SIZE - 1] = '\0';
        return 1;
    }

    return 0;
}

// ------------------------------------------------------------------
// ollama_embed_deinit
//   Called once per query to release resources.
// ------------------------------------------------------------------
void ollama_embed_deinit(UDF_INIT *initid)
{
    if (initid->ptr) {
        free(initid->ptr);
        initid->ptr = nullptr;
    }
}

// ------------------------------------------------------------------
// ollama_embed
//   Main function: called for every row that references the UDF.
//   Returns a binary string of EXPECTED_DIMS * 4 bytes representing
//   the embedding in MySQL's VECTOR binary format (little-endian
//   IEEE 754 single-precision floats, packed contiguously).
// ------------------------------------------------------------------
char *ollama_embed(UDF_INIT *initid, UDF_ARGS *args,
                   char * /*result*/, unsigned long *length,
                   char *is_null, char *error)
{
    *is_null = 0;
    *error   = 0;

    if (!args->args[0] || args->lengths[0] == 0) {
        *is_null = 1;
        return nullptr;
    }

    // Copy the argument to a NUL-terminated C string
    std::string text(args->args[0], args->lengths[0]);

    char errmsg[MYSQL_ERRMSG_SIZE] = {};
    std::vector<float> embedding = fetch_embedding(text.c_str(), errmsg, sizeof(errmsg));

    if (embedding.empty()) {
        // Log the error message; MySQL surfaces it as a warning/error
        // We signal the error via the error flag
        *error   = 1;
        *is_null = 1;
        // MySQL reads the message from the UDF_INIT message buffer on
        // init errors; at runtime we write to the MySQL error log via
        // fprintf to stderr (visible in mysqld's error log).
        fprintf(stderr, "%s\n", errmsg);
        return nullptr;
    }

    // Pack floats as little-endian IEEE 754 binary (MySQL VECTOR format).
    // On all modern x86/ARM platforms float is already 32-bit IEEE 754;
    // we just need to ensure little-endian byte order.
    size_t byte_len = embedding.size() * sizeof(float);
    if (byte_len > initid->max_length) {
        // Reallocate if the model returned more dimensions than expected
        char *new_buf = static_cast<char *>(realloc(initid->ptr, byte_len));
        if (!new_buf) {
            *error   = 1;
            *is_null = 1;
            return nullptr;
        }
        initid->ptr = new_buf;
        initid->max_length = static_cast<unsigned long>(byte_len);
    }

#if defined(__BYTE_ORDER__) && (__BYTE_ORDER__ == __ORDER_BIG_ENDIAN__)
    // Big-endian host: byte-swap each float to little-endian
    for (size_t i = 0; i < embedding.size(); ++i) {
        uint32_t tmp;
        memcpy(&tmp, &embedding[i], sizeof(tmp));
        tmp = __builtin_bswap32(tmp);
        memcpy(initid->ptr + i * sizeof(float), &tmp, sizeof(tmp));
    }
#else
    // Little-endian host: copy directly
    memcpy(initid->ptr, embedding.data(), byte_len);
#endif

    *length = static_cast<unsigned long>(byte_len);
    return initid->ptr;
}

} // extern "C"
