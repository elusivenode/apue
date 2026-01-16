#include "time.h"
#include <time.h>

long long utc_timestamp(void) {
    return (long long)time(NULL);
}
