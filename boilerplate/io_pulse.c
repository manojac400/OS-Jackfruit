#include <stdio.h>
#include <unistd.h>

int main() {
    printf("I/O pulse started\n");
    for(int i = 0; i < 100; i++) {
        printf("Pulse %d\n", i);
        usleep(100000);
    }
    return 0;
}
