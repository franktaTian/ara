#include <stdio.h>
#include <math.h>
#include <stddef.h>
#include <stdlib.h>

#include <riscv_vector.h>

static const float ch_2[2] = {0.70710678118654752440f, 0.70710678118654752440f};
static const float cg_2[2] = {0.70710678118654752440f, -(0.70710678118654752440f)};

typedef enum {
  gsl_wavelet_forward = 1,
  gsl_wavelet_backward = -1
} gsl_wavelet_direction;

typedef struct {
  const char *name;
  int (*init) ( const float **h1, const float **g1,
  const float **h2, const float **g2,
  size_t * nc,
  size_t * offset,
  size_t member );
} gsl_wavelet_type;

typedef struct {
  // Pointers to the filters
  const float *h1;
  const float *g1;
  // Number of filter components
  size_t nc;
  // Offset for center support
  size_t offset;
} gsl_wavelet;

typedef struct {
  float *scratch;
  int n;
} gsl_wavelet_workspace;

void gsl_wavelet_transform (float *data, size_t n, float* buf);
void gsl_wavelet_transform_vector(float *data, size_t n, float* buf);
static inline void dwt_step(const gsl_wavelet *w, float *samples, size_t n, float *buf);
static inline void dwt_step_vector(const gsl_wavelet *w, float *samples, size_t n, float *buf);
