/* Wrapper header for translate-c, shared across all modules that use librdkafka
 * so the generated C types are identical everywhere. Includes the mock API used
 * by benchmarks. */
#include <librdkafka/rdkafka.h>
#include <librdkafka/rdkafka_mock.h>
