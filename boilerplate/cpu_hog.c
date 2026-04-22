#include <stdio.h>
#include <unistd.h>

int main() {
    printf("CPU hog started\n");
    while(1) {
        for(long i = 0; i < 10000000; i++);
    }
    return 0;
}
