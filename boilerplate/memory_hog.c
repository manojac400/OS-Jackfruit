#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    size_t size_mb = 100;  // Default 100 MB
    if (argc > 1) {
        size_mb = atoi(argv[1]);
    }
    
    size_t size_bytes = size_mb * 1024 * 1024;
    
    printf("Attempting to allocate %zu MB of memory...\n", size_mb);
    fflush(stdout);
    
    char *mem = malloc(size_bytes);
    if (!mem) {
        printf("Memory allocation failed!\n");
        return 1;
    }
    
    printf("Memory allocated successfully. Touching pages...\n");
    fflush(stdout);
    
    // Touch each page to force actual allocation
    for (size_t i = 0; i < size_bytes; i += 4096) {
        mem[i] = 1;
    }
    
    printf("All %zu MB allocated. Sleeping for 30 seconds...\n", size_mb);
    fflush(stdout);
    
    sleep(30);
    
    free(mem);
    printf("Memory freed. Exiting.\n");
    return 0;
}
