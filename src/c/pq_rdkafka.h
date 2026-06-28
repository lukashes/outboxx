/* Wrapper header for translate-c. Combined libpq + librdkafka bindings, used by
 * the shared test helpers which touch both PostgreSQL and Kafka. */
#include <libpq-fe.h>
#include <librdkafka/rdkafka.h>
