/* Dev/test C bindings for build-system translate-c: the prod headers plus
 * librdkafka's mock cluster API. Imported as "c" by tests and benchmarks, so the
 * mock stays out of the production binary. */
#include <libpq-fe.h>
#include <librdkafka/rdkafka.h>
#include <librdkafka/rdkafka_mock.h>
