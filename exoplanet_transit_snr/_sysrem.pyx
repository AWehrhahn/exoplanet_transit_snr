#define NPY_NO_DEPRECATED_API NPY_1_7_API_VERSION

cimport cython
cimport numpy as np

import numpy as np
from scipy.sparse import csc_array
from tqdm import tqdm

from libc.math cimport INFINITY, NAN, isnan

DTYPE = np.float64

@cython.boundscheck(False)  # Deactivate bounds checking
@cython.wraparound(False)   # Deactivate negative indexing.
@cython.cdivision(True) # Disable division by zero error
def _sysrem_run(double[:, ::1] input_data, int num, double[:, ::1] errors_squared, int iterations=1000, float tolerance=1e-8):

    cdef Py_ssize_t n, m, i, j, k
    cdef Py_ssize_t stars_dim = input_data.shape[0]
    cdef Py_ssize_t epoch_dim = input_data.shape[1]
    cdef double diff1, diff2, diff

    # Create all the memory we need for SYSREM
    cdef double[::1] c = np.zeros(stars_dim, dtype=DTYPE)
    cdef double[::1] a = np.ones(epoch_dim, dtype=DTYPE)
    cdef double[::1] c_loc = np.zeros(stars_dim, dtype=DTYPE)
    cdef double[::1] a_loc = np.zeros(epoch_dim, dtype=DTYPE)
    cdef double[::1] c_numerator = np.zeros(stars_dim, dtype=DTYPE)
    cdef double[::1] c_denominator = np.zeros(stars_dim, dtype=DTYPE)
    cdef double[::1] a_numerator = np.zeros(epoch_dim, dtype=DTYPE)
    cdef double[::1] a_denominator = np.zeros(epoch_dim, dtype=DTYPE)
    cdef double[:, ::1] syserr = np.zeros((stars_dim, epoch_dim), dtype=DTYPE)


    # remove the median as the first component
    cdef double[:] median = np.nanmedian(input_data, axis=0)
    cdef double[:, ::1] residuals = np.zeros((stars_dim, epoch_dim), dtype=DTYPE)
    cdef double prev_diff = INFINITY

    for i in range(stars_dim):
        for j in range(epoch_dim):
            residuals[i, j] = input_data[i, j] - median[j]

    syserrors = [None] * (num + 1)
    syserrors[0] = median

    for n in tqdm(range(num), total=num):
        # minimize a and c values for a number of iterations, iter
        for m in tqdm(range(iterations), total=iterations, leave=False):
            # Using the initial guesses for each a value of each epoch, minimize c for each star
            for i in range(stars_dim):
                c_numerator[i] = 0
                c_denominator[i] = 0
                k = 0
                for j in range(epoch_dim):
                    if (not isnan(residuals[i, j])) and (errors_squared[i, j] != 0):
                        c_numerator[i] += a[j] * residuals[i, j] / errors_squared[i, j]
                        c_denominator[i] += a[j] ** 2 / errors_squared[i, j]
                        k += 1
                if k > 0:
                    c_loc[i] = c_numerator[i] / c_denominator[i]
                else:
                    c_loc[i] = NAN

            # Using the c values found above, minimize a for each epoch
            for j in range(epoch_dim):
                a_numerator[j] = 0
                a_denominator[j] = 0
                k = 0
                for i in range(stars_dim):
                    if (not isnan(residuals[i, j])) and (errors_squared[i, j] != 0):
                        a_numerator[j] += c_loc[i] * residuals[i, j] / errors_squared[i, j]
                        a_denominator[j] += c_loc[i] ** 2 / errors_squared[i, j]
                        k += 1
                if k > 0:
                    a_loc[j] = a_numerator[j] / a_denominator[j]
                else:
                    a_loc[j] = NAN

            diff1 = 0
            for i in range(stars_dim):
                diff1 += (c_loc[i] - c[i]) ** 2
            diff1 /= stars_dim
            diff2 = 0
            for j in range(epoch_dim):
                diff2 += (a_loc[j] - a[j]) ** 2
            diff2 /= epoch_dim
            diff = diff1 + diff2

            # Swap the pointers to the memory
            c, c_loc = c_loc, c
            a, a_loc = a_loc, a
            if (diff < tolerance) or (diff > prev_diff):
                break
            prev_diff = diff

        # Create a matrix for the systematic errors:
        # syserr = np.zeros((stars_dim, epoch_dim))
        for i in range(stars_dim):
            for j in range(epoch_dim):
                syserr[i, j] = c[i] * a[j]
                # Remove the systematic error
                residuals[i, j] -= syserr[i, j]

        syserrors[n + 1] = np.copy(syserr)

    return residuals, syserrors


@cython.boundscheck(False)  # Deactivate bounds checking
@cython.wraparound(False)   # Deactivate negative indexing.
@cython.cdivision(True) # Disable division by zero error
@cython.nonecheck(False)
def sysrem_with_projection(double[:] a, double[:] c, double[:] t, double[:] residuals, double[:] errors_squared,
                        double[:, ::1] proj_indices, double[:, ::1] proj_indptr, double[:, ::1] proj_values):

    cdef Py_ssize_t k, i, j, n, m
    cdef Py_ssize_t stars_dim = t.size
    cdef Py_ssize_t epoch_dim = a.size
    cdef int[:] idx
    cdef double[:] values
    cdef double tmp, tmp2
    cdef double[:] c_numerator = np.zeros(stars_dim, dtype=DTYPE)
    cdef double[:] c_denominator = np.zeros(stars_dim, dtype=DTYPE)
    cdef double[:] c_loc

    for i in tqdm(range(epoch_dim), leave=False):
        p_data = proj_values[i]
        p_indices = proj_indices[i]
        p_indptr = proj_indptr[i]
        for k in tqdm(range(stars_dim), leave=False):
            # TODO: figure the math out
            idx = p_indices[k]
            values = p_data[k]
            values_all = p_data[idx]

            # p[idx] @ c
            tmp = 0
            for n in range(len(idx)):
                j = idx[n]
                tmp += values_all[n] * c[j]

            # Calculate c
            for n in range(len(idx)):
                tmp2 = tmp - values[n] * c[k]
                c_numerator[k] += a[i] * t[j] / errors_squared[j] * values[n] * (residuals[j] - a[i] * t[j] * tmp2)
                c_denominator[k] += a[i]**2 * t[j]**2 / errors_squared[j] * values[n]**2



    return c_numerator, c_denominator
