#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <time.h>

int main(int argc, char *argv[]) {
    int size_mb = 100;
    if (argc > 1) size_mb = atoi(argv[1]);
    
    fprintf(stderr, "Starting memory hog: allocating %d MB\n", size_mb);
    
    char *mem = malloc(size_mb * 1024 * 1024);
    if (!mem) {
        fprintf(stderr, "malloc failed!\n");
        return 1;
    }
    
    // Touch every page to force physical allocation
    for (int i = 0; i < size_mb * 1024 * 1024; i += 4096) {
        mem[i] = 1;
    }
    
    fprintf(stderr, "Allocated %d MB successfully. Sleeping for 60 seconds...\n", size_mb);
    
    // Sleep for 60 seconds
    sleep(60);
    
    free(mem);
    fprintf(stderr, "Memory freed. Exiting.\n");
    return 0;
}
