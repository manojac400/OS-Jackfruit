#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    size_t size = 100 * 1024 * 1024;
    if (argc > 1) size = atoi(argv[1]) * 1024 * 1024;
    
    char *mem = malloc(size);
    if (!mem) return 1;
    
    memset(mem, 0, size);
    printf("Allocated %zu MB\n", size / (1024*1024));
    sleep(30);
    free(mem);
    return 0;
}
