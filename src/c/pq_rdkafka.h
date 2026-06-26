/* Wrapper header for translate-c (Zig 0.16 build-system C translation).
 * Combined libpq + librdkafka bindings, used by the shared test helpers which
 * touch both PostgreSQL and Kafka. */
#include <libpq-fe.h>
#include <librdkafka/rdkafka.h>
