// Copyright 2022 ETH Zurich and University of Bologna.
//
// SPDX-License-Identifier: Apache-2.0
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//    http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

// Author: Matteo Perotti, ETH Zurich

#include <stdint.h>
#include <string.h>

#include "kernel/wavelet.h"
#include "printf.h"
#include "runtime.h"

#define CHECK
//#define DEBUG

#define THRESHOLD 0.01
#define FABS(x) ((x < 0) ? -x : x)

int similarity_check(double a, double b, double threshold) {
  double diff = a - b;
  if (FABS(diff) > threshold)
    return 0;
  else
    return 1;
}

extern uint64_t DWT_LEN;
extern float data_s[] __attribute__((aligned(4 * NR_LANES)));
extern float data_v[] __attribute__((aligned(4 * NR_LANES)));
extern float    buf[] __attribute__((aligned(4 * NR_LANES)));

int main() {
  printf("\n");
  printf("=========\n");
  printf("=  DWT  =\n");
  printf("=========\n");
  printf("\n");
  printf("\n");

  int64_t runtime;
  int error = 0;

  printf("Computing DWT with %u samples\n", DWT_LEN);

#ifdef DEBUG
  for (int i = 0; i < DWT_LEN; ++i) {
    printf("data_s[%d] = %f\n", i, data_s[i]);
    printf("data_v[%d] = %f\n", i, data_v[i]);
  }
#endif

  printf("Scalar DWT...\n");
  start_timer();
  gsl_wavelet_transform(data_s, DWT_LEN, buf);
  stop_timer();

  runtime = get_timer();
  printf("The scalar DWT execution took %d cycles.\n", runtime);

  printf("Vector DWT...\n");
  start_timer();
  gsl_wavelet_transform_vector(data_v, DWT_LEN, buf);
  stop_timer();

  runtime = get_timer();
  printf("The vector DWT execution took %d cycles.\n", runtime);

#ifdef CHECK
  for (int i = 0; i < DWT_LEN; ++i) {
    if (!similarity_check(data_s[i], data_v[i], THRESHOLD)) {
      error = 1;
      printf("Error at index %d. %f != %f\n", i, data_v[i], data_s[i]);
    }
  }
#endif

  return error;
}
