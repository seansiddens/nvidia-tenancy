#include <stdlib.h>
#include <stdint.h>
#include <iostream>
#include <cuda_runtime.h>
#include <chrono>
#include <unistd.h>

enum class KernelType {
    DELAY,
    BUSY
};

#define cudaCheckErrors(msg) \
  do { \
    cudaError_t __err = cudaGetLastError(); \
    if (__err != cudaSuccess) { \
        fprintf(stderr, "Fatal error: %s (%s at %s:%d)\n", \
            msg, cudaGetErrorString(__err), \
            __FILE__, __LINE__); \
        fprintf(stderr, "*** FAILED - ABORTING\n"); \
        exit(1); \
    } \
  } while (0)


/* Kernel which does work for some fixed duration of time (specified in milliseconds).
   https://docs.nvidia.com/cuda/cuda-c-programming-guide/index.html#time-function
   "Sampling this counter at the beginning and at the end of a kernel, taking the difference of the two samples, 
   and recording the result per thread provides a measure for each thread of the number of clock cycles taken by the device 
   to completely execute the thread, but not of the number of clock cycles the device actually spent executing thread instructions. 
   The former number is greater than the latter since threads are time sliced."
*/
__global__ void delay_kernel(float *d_out, float *d_in, int n, uint64_t duration, int clock_rate_khz) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;
    if (idx < n) {
        uint64_t start_clock = clock64();
        uint64_t duration_clocks = (uint64_t)(duration * clock_rate_khz);
        float temp = d_in[idx];
        while (clock64() - start_clock < duration_clocks) {
            temp += sinf(temp);
        }
        d_out[idx] = temp;
    }
}


/** Kernel which does some fixed amount of work. */
__global__ void busy_kernel(float *d_out, float *d_in, int n, uint32_t num_iterations) {
    int idx = blockIdx.x * blockDim.x + threadIdx.x;

    if (idx < n) {
        float temp = d_in[idx];
        // Loop that does some work to prevent compiler optimization
        for (int i = 0; i < num_iterations; i++) {
            temp += sinf(temp);
        }
        d_out[idx] = temp;
    }
}

int main(int argc, char *argv[]){
    if (argc != 3) {
        std::cerr << "Usage: " << argv[0] << " --delay <duration> or --busy <iterations>" << std::endl;   
        return 1;
    }

    KernelType kernel_type;
    int duration;
    int num_iterations;
    if (strcmp(argv[1], "--delay") == 0) {
        kernel_type = KernelType::DELAY;
        duration = atoi(argv[2]);
        if (duration <= 0) {
            std::cerr << "Duration must be > 0" << std::endl;
            return 1;
        }
    } else if (strcmp(argv[1], "--busy") == 0) {
        kernel_type = KernelType::BUSY;
        num_iterations = atoi(argv[2]);
        if (num_iterations <= 0) {
            std::cerr << "Iterations must be > 0" << std::endl;
            return 1;
        }
    } else {
        std::cerr << "Usage: " << argv[0] << " --delay or --busy" << std::endl;   
        return 1;
    }
    

    // Kernel launch params.
    int num_workgroups = 1024;
    int workgroup_size = 128;

    // Scratchpad
    int n = 1024;
    float *h_in = (float*)malloc(n * sizeof(float));
    float *h_out = (float*)malloc(n * sizeof(float));
    for (int i = 0; i < n; i++) {
        h_in[i] = (float)i;
    }

    int pid = getpid();

    // Get device info.
    int device_id = 0;
    cudaDeviceProp prop;
    cudaGetDeviceProperties(&prop, device_id); 
    std::cout << "[" << pid << "] Device: " << prop.name << std::endl;
    int clock_rate_khz;
    cudaDeviceGetAttribute(&clock_rate_khz, cudaDevAttrClockRate, device_id);
    std::cout << "[" << pid << "] Clock rate: " << clock_rate_khz << " kHz" << std::endl;
    if (kernel_type == KernelType::DELAY) {
        std::cout << "[" << pid << "] Duration: " << duration << " ms" << std::endl;
    } else {
        std::cout << "[" << pid << "] Iterations: " << num_iterations << std::endl;
    }

    // Allocate device memory
    float *d_in, *d_out;
    cudaMalloc(&d_in, n * sizeof(float));
    cudaMalloc(&d_out, n * sizeof(float));

    // Copy input data to device
    cudaMemcpy(d_in, h_in, n * sizeof(float), cudaMemcpyHostToDevice);

    // Launch the kernel
    std::cout << "[" << pid << "] Launching kernel" << std::endl;
    auto now = std::chrono::high_resolution_clock::now();
    if (kernel_type == KernelType::DELAY)
        delay_kernel<<<num_workgroups, workgroup_size>>>(d_out, d_in, n, duration, clock_rate_khz);
    else
        busy_kernel<<<num_workgroups, workgroup_size>>>(d_out, d_in, n, num_iterations);
    cudaDeviceSynchronize();
    cudaCheckErrors("kernel fail");
    auto total_time = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::high_resolution_clock::now() - now);
    std::cout << "[" << pid << "] Total time (host): " << total_time.count() << " ms" << std::endl;
    
    // Copy result back to host
    cudaMemcpy(h_out, d_out, n * sizeof(float), cudaMemcpyDeviceToHost);

    // Cleanup
    free(h_in);
    free(h_out);
    cudaFree(d_in);
    cudaFree(d_out);

    return 0;
}