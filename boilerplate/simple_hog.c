#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    int size_mb = 100;
    if (argc > 1) size_mb = atoi(argv[1]);
    
    printf("Allocating %d MB...\n", size_mb);
    char *mem = malloc(size_mb * 1024 * 1024);
    if (mem) {
        memset(mem, 1, size_mb * 1024 * 1024);
        printf("Allocated %d MB. Sleeping...\n", size_mb);
        sleep(60);
        free(mem);
    }
    return 0;
}
