#include <stdio.h>
#include "time.h"

int main(void) {
    printf("hello from c (%lld)\n", utc_timestamp());
    return 0;
}
