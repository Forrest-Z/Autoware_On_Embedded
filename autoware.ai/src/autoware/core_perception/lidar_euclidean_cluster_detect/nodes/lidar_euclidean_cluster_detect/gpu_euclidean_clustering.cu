/*
 ============================================================================
 Name        : gpu_euclidean_clustering.cu
 Author      : AnhNV91
 Version     : 1.0
 Description : Clustering analysis using Euclidean distance and single linkage
 ============================================================================
 */

#include "gpu_euclidean_clustering.h"
#include <cuda.h>
#include <cuda_runtime.h>
#include <thrust/device_ptr.h>
#include <thrust/device_vector.h>
#include <thrust/copy.h>
#include <thrust/scan.h>
#include <thrust/fill.h>

#include <time.h>
#include <sys/time.h>

#define MAX_SHARED_SIZE 2048
#define BLOCK_SIZE_X 1024

//#define SERIAL 1

static FILE* execution_time_fp;
static FILE* response_time_fp;
static FILE* remain_time_fp;

inline void gassert(cudaError_t err_code, const char *file, int line)
{
  if (err_code != cudaSuccess)
  {
    fprintf(stderr, "Error: %s %s %d\n", cudaGetErrorString(err_code), file, line);
    cudaDeviceReset();
    exit(EXIT_FAILURE);
  }
}

#define checkCudaErrors(val) gassert(val, __FILE__, __LINE__)

GpuEuclideanCluster::GpuEuclideanCluster()
{
  x_ = NULL;
  y_ = NULL;
  z_ = NULL;

  size_ = 0;
  threshold_ = 0;
  cluster_indices_ = NULL;
  cluster_indices_host_ = NULL;
  min_cluster_pts_ = 0;
  max_cluster_pts_ = 1000000000;
  cluster_num_ = 0;

  if(GPU_PROFILING == 1){
		cudaEventCreate(&e_event_start);
		cudaEventCreate(&e_event_stop);
    cudaEventCreate(&r_event_start);
		cudaEventCreate(&r_event_stop);
	}
}

void GpuEuclideanCluster::setInputPoints(float *x, float *y, float *z, int size)
{
  size_ = size;
  checkCudaErrors(cudaMalloc(&x_, size_ * sizeof(float)));
  checkCudaErrors(cudaMalloc(&y_, size_ * sizeof(float)));
  checkCudaErrors(cudaMalloc(&z_, size_ * sizeof(float)));

  checkCudaErrors(cudaMemcpy(x_, x, size_ * sizeof(float), cudaMemcpyHostToDevice));
  checkCudaErrors(cudaMemcpy(y_, y, size_ * sizeof(float), cudaMemcpyHostToDevice));
  checkCudaErrors(cudaMemcpy(z_, z, size_ * sizeof(float), cudaMemcpyHostToDevice));

  checkCudaErrors(cudaMalloc(&cluster_indices_, size_ * sizeof(int)));
  cluster_indices_host_ = (int *) malloc(size_ * sizeof(int));
}

void GpuEuclideanCluster::setThreshold(double threshold)
{
  threshold_ = threshold;
}

void GpuEuclideanCluster::setMinClusterPts(int min_cluster_pts)
{
  min_cluster_pts_ = min_cluster_pts;
}

void GpuEuclideanCluster::setMaxClusterPts(int max_cluster_pts)
{
  max_cluster_pts_ = max_cluster_pts;
}

/* Initially, each point is assigned to an individual cluster.
 *
 */

extern "C" __global__ void pclEuclideanInitialize(int *cluster_indices, int size)
{  
  for (int index = threadIdx.x + blockIdx.x * blockDim.x; index < size; index += blockDim.x * gridDim.x){
    cluster_indices[index] = index;
  }
}

/* Connected component labeling points at GPU block thread level.
 * Input list of points is divided into multiple smaller groups.
 * Each group of point is assigned to a block of GPU thread.
 * Each thread in a block handles one point in the group. It iterates over
 * points in the group and compare the distance between the current point A
 * and the point B it has to handle.
 *
 * If the distance between A and B is less than the threshold, then those
 * two points belong to a same connected component and the cluster_changed
 * is marked by 1.
 *
 * A synchronization is called to make sure all thread in the block finish A
 * before moving to the update phase.
 * After finishing checking cluster_changed, threads update the cluster
 * index of all points. If a thread has cluster_changed is 1, then the corresponding
 * cluster of the point it is handling is changed to the cluster of B. Otherwise
 * the original cluster of A remains unchanged.
 *
 * Another synchronization is called before all threads in the block move to
 * other points after done checking A.
 *
 * After this kernel finishes, all points in each block are labeled.
 */
extern "C" __global__ void blockLabelling(float *x, float *y, float *z, int *cluster_indices, int size, float threshold)
{
  
  int block_start = blockIdx.x * blockDim.x;
  int block_end = (block_start + blockDim.x <= size) ? (block_start + blockDim.x) : size;
  int row = threadIdx.x + block_start;
  __shared__ int local_offset[BLOCK_SIZE_X];
  __shared__ float local_x[BLOCK_SIZE_X];
  __shared__ float local_y[BLOCK_SIZE_X];
  __shared__ float local_z[BLOCK_SIZE_X];
  __shared__ int local_cluster_changed[BLOCK_SIZE_X];


  if (row < block_end)
  {
    local_offset[threadIdx.x] = threadIdx.x;
    local_x[threadIdx.x] = x[row];
    local_y[threadIdx.x] = y[row];
    local_z[threadIdx.x] = z[row];
    __syncthreads();

    for (int column = block_start; column < block_end; column++)
    {
      float tmp_x = local_x[threadIdx.x] - local_x[column - block_start];
      float tmp_y = local_y[threadIdx.x] - local_y[column - block_start];
      float tmp_z = local_z[threadIdx.x] - local_z[column - block_start];
      int column_offset = local_offset[column - block_start];
      int row_offset = local_offset[threadIdx.x];

      local_cluster_changed[threadIdx.x] = 0;
      __syncthreads();

      if (row > column && column_offset != row_offset && norm3df(tmp_x, tmp_y, tmp_z) < threshold)
        local_cluster_changed[row_offset] = 1;
      __syncthreads();

      local_offset[threadIdx.x] = (local_cluster_changed[row_offset] == 1) ? column_offset : row_offset;
      __syncthreads();
    }

    __syncthreads();

    int new_cluster = cluster_indices[block_start + local_offset[threadIdx.x]];

    __syncthreads();

    cluster_indices[row] = new_cluster;
  }
}

extern "C" __global__ void blockLabelling_with_slicing(float *x, float *y, float *z, int *cluster_indices, int size, float threshold, int slice_id, int slice_cnt)
{
  
  int total_block_start = blockIdx.x * blockDim.x;
  int total_block_end = (total_block_start + blockDim.x <= size) ? (total_block_start + blockDim.x) : size;  
  
  int quotient = (total_block_start-total_block_end) / slice_cnt;
  int remainder = (total_block_start-total_block_end) % slice_cnt;

  int block_start = quotient*(slice_id+1);
  int block_end = block_start + quotient;
  if( (slice_id+1) == slice_cnt) block_end += remainder;



  int row = threadIdx.x + block_start;
  __shared__ int local_offset[BLOCK_SIZE_X];
  __shared__ float local_x[BLOCK_SIZE_X];
  __shared__ float local_y[BLOCK_SIZE_X];
  __shared__ float local_z[BLOCK_SIZE_X];
  __shared__ int local_cluster_changed[BLOCK_SIZE_X];

  if (row < block_end)
  {
    local_offset[threadIdx.x] = threadIdx.x;
    local_x[threadIdx.x] = x[row];
    local_y[threadIdx.x] = y[row];
    local_z[threadIdx.x] = z[row];
    __syncthreads();
    
    for (int column = block_start; column < block_end; column++)
    {
      float tmp_x = local_x[threadIdx.x] - local_x[column - block_start];
      float tmp_y = local_y[threadIdx.x] - local_y[column - block_start];
      float tmp_z = local_z[threadIdx.x] - local_z[column - block_start];
      int column_offset = local_offset[column - block_start];
      int row_offset = local_offset[threadIdx.x];

      local_cluster_changed[threadIdx.x] = 0;
      __syncthreads();

      if (row > column && column_offset != row_offset && norm3df(tmp_x, tmp_y, tmp_z) < threshold)
        local_cluster_changed[row_offset] = 1;
      __syncthreads();

      local_offset[threadIdx.x] = (local_cluster_changed[row_offset] == 1) ? column_offset : row_offset;
      __syncthreads();
    }

    __syncthreads();

    int new_cluster = cluster_indices[block_start + local_offset[threadIdx.x]];

    __syncthreads();

    cluster_indices[row] = new_cluster;
  }
}

/* These kernels are used to collect remained clusters after each labeling phase.
 *
 * Basically, in each labeling phases, several clusters are merged together.
 *
 * The first kernel scans over the cluster_indices array and marks the cluster_mark
 * element corresponding with the cluster of the current point by 1. If a cluster
 * does not exists in the current phase (which means it was merged to some other
 * clusters), then its cluster_mark is 0.
 *
 * The second kernel scans over the original cluster_indices again and copy those
 * indices to new location on the target_clusters.
 */
extern "C" __global__ void clusterMark(int *cluster_list, int *cluster_mark, int size)
{
  for (int i = threadIdx.x + blockIdx.x * blockDim.x; i < size; i += blockDim.x * gridDim.x)
    cluster_mark[cluster_list[i]] = 1;
}

extern "C" __global__ void
clusterCollector(int *old_cluster_list, int *new_cluster_list, int *cluster_location, int size)
{
  for (int i = threadIdx.x + blockIdx.x * blockDim.x; i < size; i += blockDim.x * gridDim.x){    
    new_cluster_list[cluster_location[old_cluster_list[i]]] = old_cluster_list[i];
  }
}

/* Create a cluster matrix.
 *
 * A cluster matrix is to record the relationship between each pair
 * of clusters. If a pair of cluster x and y are connected, then
 * the matrix element [x][y] are 1. Otherwise it is 0. Notice that
 * only the lower half of the matrix is used.
 *
 * To build this matrix, each GPU thread handles one point A, iterates
 * over all points B, and compare distance between A and B. Assuming
 * that A belongs to a cluster x, and B belongs to cluster y. If their
 * distance is less than the threshold, then the matrix element [x][y]
 * is set to 1.
 */
extern "C" __global__ void
buildClusterMatrix(float *x, float *y, float *z, int *cluster_indices, int *cluster_matrix, int *cluster_offset,
                   int size, int cluster_num, float threshold)
{
  int index = threadIdx.x + blockIdx.x * blockDim.x;
  int stride = blockDim.x * gridDim.x;
  __shared__ float local_x[BLOCK_SIZE_X];
  __shared__ float local_y[BLOCK_SIZE_X];
  __shared__ float local_z[BLOCK_SIZE_X];

  if (index>size)
    return;

  for (int column = index; column < size; column += stride)
  {
    local_x[threadIdx.x] = x[column];
    local_y[threadIdx.x] = y[column];
    local_z[threadIdx.x] = z[column];
    int column_cluster = cluster_indices[column];
    int cc_offset = cluster_offset[column_cluster];

    __syncthreads();

    for (int row = 0; row < column; row++)
    {
      float tmp_x = x[row] - local_x[threadIdx.x];
      float tmp_y = y[row] - local_y[threadIdx.x];
      float tmp_z = z[row] - local_z[threadIdx.x];
      int row_cluster = cluster_indices[row];
      int rc_offset = cluster_offset[row_cluster];

      if (row_cluster != column_cluster && norm3df(tmp_x, tmp_y, tmp_z) < threshold)
        cluster_matrix[rc_offset * cluster_num + cc_offset] = 1;
    }
    __syncthreads();
  }
}

extern "C" __global__ void
buildClusterMatrix_with_slicing(float *x, float *y, float *z, int *cluster_indices, int *cluster_matrix, int *cluster_offset,
                   int size, int cluster_num, float threshold, int slice_id, int slice_cnt)
{
  int index = threadIdx.x + blockIdx.x * blockDim.x;
  int stride = blockDim.x * gridDim.x;
  __shared__ float local_x[BLOCK_SIZE_X];
  __shared__ float local_y[BLOCK_SIZE_X];
  __shared__ float local_z[BLOCK_SIZE_X];

  if (index>size)
    return;

  int quotient = size/slice_cnt;
  int remainder = size%slice_cnt;
  int column_start = index + slice_id * quotient;
  int column_end = column_start + remainder;
  if((slice_id + 1) == slice_cnt) column_end + remainder;
  if(column_end > size) column_end = size;

  // for (int column = index; column < size; column += stride)
  for (int column = column_start; column < column_end; column += stride)
  {
    local_x[threadIdx.x] = x[column];
    local_y[threadIdx.x] = y[column];
    local_z[threadIdx.x] = z[column];
    int column_cluster = cluster_indices[column];
    int cc_offset = cluster_offset[column_cluster];

    __syncthreads();

    // int row_start = slice_id * column/slice_cnt;
    // int row_end = row_start + column/slice_cnt;
    // if((slice_id + 1) == slice_cnt) row_end + column%slice_cnt;
    // if(row_end > column) row_end = column;

    // for (int row = row_start; row < row_end; row++)
    for (int row = 0; row < column; row++)
    {
      float tmp_x = x[row] - local_x[threadIdx.x];
      float tmp_y = y[row] - local_y[threadIdx.x];
      float tmp_z = z[row] - local_z[threadIdx.x];
      int row_cluster = cluster_indices[row];
      int rc_offset = cluster_offset[row_cluster];

      if (row_cluster != column_cluster && norm3df(tmp_x, tmp_y, tmp_z) < threshold)
        cluster_matrix[rc_offset * cluster_num + cc_offset] = 1;
    }
    __syncthreads();
  }
}

/* Merge clusters based on the cluster_matrix.
 *
 * This merge process is done per block. The input list of clusters
 * are divided into smaller chunks to be handled by GPU blocks.
 *
 * Each thread in a block handles one row of the matrix and iterates
 * over all columns of the matrix. A synchronization per each iteration
 * is needed to make sure all threads done merging clusters in the
 * current column before moving to the next column.
 *
 * In each iteration, each thread check if the cluster corresponding
 * with the current row is connected to the cluster corresponding to the
 * current column. If so, then the cluster of the row is changed (merged)
 * to the cluster of the column.
 */
extern "C" __global__ void mergeClusters(int *cluster_matrix, int *cluster_list, int cluster_num)
{
  int row_start = blockIdx.x * blockDim.x;
  int row_end = (row_start + blockDim.x <= cluster_num) ? row_start + blockDim.x : cluster_num;
  int col = row_start + threadIdx.x;
  __shared__ int local_changed[BLOCK_SIZE_X];
  __shared__ int local_offset[BLOCK_SIZE_X];

  /* The cluster matrix is symmetric, so the
   * number of rows and columns are the same
   */
  if (col < row_end)
  {
    local_offset[threadIdx.x] = threadIdx.x;

    __syncthreads();

    for (int row = row_start; row < row_end; row++)
    {
      int col_offset = local_offset[threadIdx.x];
      int row_offset = local_offset[row - row_start];

      local_changed[threadIdx.x] = 0;
      __syncthreads();

      if (row < col && row_offset != col_offset && (cluster_matrix[row * cluster_num + col] == 1))
        local_changed[col_offset] = 1;
      __syncthreads();

      local_offset[threadIdx.x] = (local_changed[col_offset] == 1) ? row_offset : col_offset;
      __syncthreads();
    }

    __syncthreads();

    int new_cluster = cluster_list[row_start + local_offset[threadIdx.x]];

    __syncthreads();
    cluster_list[col] = new_cluster;
  }
}

/* Reflex the change in the cluster merging step
 * to cluster indices of all input points.
 *
 * Clusters of input points are changed to the target clusters
 * corresponding with their source clusters.
 */
extern "C" __global__ void reflexClusterChanges(int *cluster_indices, int *cluster_offset, int *cluster_list, int size)
{
  for (int i = threadIdx.x + blockIdx.x * blockDim.x; i < size; i += blockDim.x * gridDim.x)
    cluster_indices[i] = cluster_list[cluster_offset[cluster_indices[i]]];
}

/* Rebuild cluster matrix after merging clusters.
 *
 * After several cluster are merged together, the number of clusters
 * reduces and the cluster matrix needs to be rebuilt.
 *
 * Each thread iterate over rows of one column of the source matrix.
 * If a element [x][y] of the source matrix is 1, then the element
 * [m][n] of the target matrix, in which m and n are the
 * new clusters of x and y, is set to 1.
 */
extern "C" __global__ void
rebuildClusterMatrix(int *old_cluster_matrix, int *new_clusters, int *new_cluster_matrix, int *new_cluster_offset,
                     int old_size, int new_size)
{
  for (int column = threadIdx.x + blockIdx.x * blockDim.x; column < old_size; column += blockDim.x * gridDim.x)
  {
    for (int row = 0; row < column; row++)
    {
      int new_row = new_cluster_offset[new_clusters[row]];
      int new_column = new_cluster_offset[new_clusters[column]];

      if (old_cluster_matrix[row * old_size + column] == 1)
        new_cluster_matrix[new_row * new_size + new_column] = 1;
    }
  }
}

/* Perform exclusive scan on the input array using
 * thurst's scan.
 *
 * The variable 'sum' records the last element of
 * the array after being scanned.
 */
void GpuEuclideanCluster::exclusiveScan(int *input, int ele_num, int *sum)
{
  thrust::device_ptr<int> dev_ptr(input);

  thrust::exclusive_scan(dev_ptr, dev_ptr + ele_num, dev_ptr);
  checkCudaErrors(cudaDeviceSynchronize());

  *sum = *(dev_ptr + ele_num - 1);
}

/* Reset the cluster indexes in the point cloud from 0.
 *
 * After merging, the cluster indexes of points are still large. Collecting
 * those large indexes is either time-consuming (without using hash) or
 * wasting memory space (using hash). By reset the cluster indexes from 0,
 * we can use hashing to collect those indexes with the space complexity equal
 * to the number of clusters.
 */
extern "C" __global__ void resetClusterIndexes(int *cluster_indices, int *cluster_offset, int size)
{
  for (int i = threadIdx.x + blockIdx.x * blockDim.x; i < size; i += blockDim.x * gridDim.x)
  {
    int old_cluster = cluster_indices[i];

    cluster_indices[i] = cluster_offset[old_cluster];
  }
}


/* Calculate the cluster indices of input points.
 *
 * Initially, the cluster index of the point at index ith
 * is set to i. This method merges cluster indices
 * of points that belong to same clusters.
 *
 * Result of this method is stored at cluster_indices_host_.
 */
void GpuEuclideanCluster::extractClustersOld()
{
  int block_x, grid_x;

  block_x = (size_ > BLOCK_SIZE_X) ? BLOCK_SIZE_X : size_;
  grid_x = (size_ - 1) / block_x + 1;

  int *cluster_offset;
  int cluster_num, old_cluster_num;

  // pclEuclideanInitialize << < grid_x, block_x >> > (cluster_indices_, size_);
  checkCudaErrors(cudaDeviceSynchronize());

  old_cluster_num = cluster_num = size_;

  checkCudaErrors(cudaMalloc(&cluster_offset, (size_ + 1) * sizeof(int)));
  checkCudaErrors(cudaMemset(cluster_offset, 0, (size_ + 1) * sizeof(int)));

  blockLabelling << < grid_x, block_x >> > (x_, y_, z_, cluster_indices_, size_, threshold_);

  clusterMark << < grid_x, block_x >> > (cluster_indices_, cluster_offset, size_);
  exclusiveScan(cluster_offset, size_ + 1, &cluster_num);

  int *cluster_list, *new_cluster_list, *tmp;

  checkCudaErrors(cudaMalloc(&cluster_list, cluster_num * sizeof(int)));
  clusterCollector << < grid_x, block_x >> > (cluster_indices_, cluster_list, cluster_offset, size_);
  checkCudaErrors(cudaDeviceSynchronize());

  int *cluster_matrix;
  int *new_cluster_matrix;

  checkCudaErrors(cudaMalloc(&cluster_matrix, cluster_num * cluster_num * sizeof(int)));
  checkCudaErrors(cudaMemset(cluster_matrix, 0, cluster_num * cluster_num * sizeof(int)));
  checkCudaErrors(cudaDeviceSynchronize());
  checkCudaErrors(cudaMalloc(&new_cluster_list, cluster_num * sizeof(int)));

  buildClusterMatrix << < grid_x, block_x >> >
                                  (x_, y_, z_, cluster_indices_, cluster_matrix, cluster_offset, size_, cluster_num, threshold_);
  checkCudaErrors(cudaDeviceSynchronize());

  int block_x2 = 0, grid_x2 = 0;


  /* Loop until there is no change in the number of clusters */
  do
  {
    old_cluster_num = cluster_num;
    block_x2 = (cluster_num > BLOCK_SIZE_X) ? BLOCK_SIZE_X : cluster_num;
    grid_x2 = (cluster_num - 1) / block_x2 + 1;

    mergeClusters << < grid_x2, block_x2 >> > (cluster_matrix, cluster_list, cluster_num);

    reflexClusterChanges << < grid_x, block_x >> > (cluster_indices_, cluster_offset, cluster_list, size_);

    checkCudaErrors(cudaMemset(cluster_offset, 0, (size_ + 1) * sizeof(int)));

    clusterMark << < grid_x2, block_x2 >> > (cluster_list, cluster_offset, cluster_num);
    exclusiveScan(cluster_offset, size_ + 1, &cluster_num);

    if (grid_x2 == 1 && cluster_num == old_cluster_num)
      break;

    clusterCollector << < grid_x2, block_x2 >> > (cluster_list, new_cluster_list, cluster_offset, old_cluster_num);
    checkCudaErrors(cudaDeviceSynchronize());

    checkCudaErrors(cudaMalloc(&new_cluster_matrix, cluster_num * cluster_num * sizeof(int)));
    checkCudaErrors(cudaMemset(new_cluster_matrix, 0, cluster_num * cluster_num * sizeof(int)));

    rebuildClusterMatrix << < grid_x2, block_x2 >> >
                                       (cluster_matrix, cluster_list, new_cluster_matrix, cluster_offset, old_cluster_num, cluster_num);
    checkCudaErrors(cudaDeviceSynchronize());

    checkCudaErrors(cudaFree(cluster_matrix));
    cluster_matrix = new_cluster_matrix;
    tmp = cluster_list;
    cluster_list = new_cluster_list;
    new_cluster_list = tmp;
  } while (1);

  cluster_num_ = cluster_num;

  resetClusterIndexes << < grid_x, block_x >> > (cluster_indices_, cluster_offset, size_);
  checkCudaErrors(cudaDeviceSynchronize());


  checkCudaErrors(cudaMemcpy(cluster_indices_host_, cluster_indices_, size_ * sizeof(int), cudaMemcpyDeviceToHost));

  checkCudaErrors(cudaFree(cluster_matrix));
  checkCudaErrors(cudaFree(cluster_list));
  checkCudaErrors(cudaFree(new_cluster_list));
  checkCudaErrors(cudaFree(cluster_offset));
}

extern "C" __global__ void mergeSelfClusters(int *cluster_matrix, int *cluster_list, int cluster_num, bool *changed)
{  
  int row_start = blockIdx.x * blockDim.x;
  int row_end = (row_start + blockDim.x <= cluster_num) ? row_start + blockDim.x : cluster_num;
  int col = row_start + threadIdx.x;
  __shared__ int local_changed[BLOCK_SIZE_X];
  __shared__ int local_offset[BLOCK_SIZE_X];
  bool block_changed = false;

  if (col < row_end)
  {
    local_offset[threadIdx.x] = threadIdx.x;

    __syncthreads();

    for (int row = row_start; row < row_end; row++)
    {
      int col_offset = local_offset[threadIdx.x];
      int row_offset = local_offset[row - row_start];

      local_changed[threadIdx.x] = 0;
      __syncthreads();

      if (row < col && row_offset != col_offset && (cluster_matrix[row * cluster_num + col] == 1))
      {
        local_changed[col_offset] = 1;
        block_changed = true;
      }
      __syncthreads();

      local_offset[threadIdx.x] = (local_changed[col_offset] == 1) ? row_offset : col_offset;
      __syncthreads();
    }

    __syncthreads();

    int new_cluster = cluster_list[row_start + local_offset[threadIdx.x]];

    __syncthreads();

    cluster_list[col] = new_cluster;


    __syncthreads();
    if (block_changed)
      *changed = true;
  }
}

extern "C" __global__ void mergeSelfClustersWithSlicing(int *cluster_matrix, int *cluster_list, int cluster_num, bool *changed, int row_start, int row_end)
{ 
  // int row_start = blockIdx.x * blockDim.x;
  // int row_end = (row_start + blockDim.x <= cluster_num) ? row_start + blockDim.x : cluster_num;
  int col = row_start + threadIdx.x;
  __shared__ int local_changed[BLOCK_SIZE_X];
  __shared__ int local_offset[BLOCK_SIZE_X];
  bool block_changed = false;

  if (col < row_end)
  {
    local_offset[threadIdx.x] = threadIdx.x;

    __syncthreads();

    for (int row = row_start; row < row_end; row++)
    {
      int col_offset = local_offset[threadIdx.x];
      int row_offset = local_offset[row - row_start];

      local_changed[threadIdx.x] = 0;
      __syncthreads();

      if (row < col && row_offset != col_offset && (cluster_matrix[row * cluster_num + col] == 1))
      {
        local_changed[col_offset] = 1;
        block_changed = true;
      }
      __syncthreads();

      local_offset[threadIdx.x] = (local_changed[col_offset] == 1) ? row_offset : col_offset;
      __syncthreads();
    }

    __syncthreads();

    int new_cluster = cluster_list[row_start + local_offset[threadIdx.x]];

    __syncthreads();

    cluster_list[col] = new_cluster;


    __syncthreads();
    if (block_changed)
      *changed = true;
  }
}


/* Merge clusters from different blocks of points.
 *
 * The relationship of those clusters are expressed by a cluster matrix.
 * The merge is done by assigning each thread in a block of GPU threads
 * to move from top to bottom of the matrix and check if there are any
 * 1 element in the matrix.
 *
 * This kernel only merge matrices that staying in a same diagonal of a
 * group of matrix. The index of the diagonal is indicated by shift_level.
 */

extern "C" __global__ void mergeInterClusters(int *cluster_matrix, int *cluster_list,
                                              int shift_level,
                                              int base_row, int base_column,
                                              int sub_matrix_row, int sub_matrix_col,
                                              int sub_matrix_offset_row, int sub_matrix_offset_col,
                                              int cluster_num, bool *changed)
{
  int col_start = (base_column + (blockIdx.x / sub_matrix_col) * sub_matrix_offset_col +
                   (blockIdx.x + shift_level - sub_matrix_col * ((blockIdx.x + shift_level) / sub_matrix_col))) *
                  blockDim.x;
  int col_end = (col_start + blockDim.x <= cluster_num) ? col_start + blockDim.x : cluster_num;
  int row_start = (base_row + (blockIdx.x / sub_matrix_row) * sub_matrix_offset_row +
                   (blockIdx.x - sub_matrix_row * (blockIdx.x / sub_matrix_row))) * blockDim.x;
  int row_end = (row_start + blockDim.x <= cluster_num) ? row_start + blockDim.x : cluster_num;
  int col = col_start + threadIdx.x;

  __shared__ int local_changed[BLOCK_SIZE_X];
  __shared__ int local_offset[BLOCK_SIZE_X];
  bool block_changed = false;

  if (col < col_end)
  {
    local_offset[threadIdx.x] = threadIdx.x;
    __syncthreads();

    for (int row = row_start; row < row_end; row++)
    {
      int col_offset = local_offset[threadIdx.x];
      int row_offset = local_offset[row - row_start];

      local_changed[threadIdx.x] = 0;
      __syncthreads();

      if (row_offset != col_offset && cluster_matrix[row * cluster_num + col] == 1)
      {
        local_changed[col_offset] = 1;
        block_changed = true;
      }
      __syncthreads();

      local_offset[threadIdx.x] = (local_changed[col_offset] == 1) ? row_offset : col_offset;
      __syncthreads();
    }

    __syncthreads();
    int new_cluster = cluster_list[col_start + local_offset[threadIdx.x]];

    __syncthreads();
    cluster_list[col] = new_cluster;

    if (block_changed)
      *changed = true;
  }
}

/* Checking if two individual blocks have any clusters that intersect.
 *
 * If there are, then the diagonal index that the block belongs to is
 * recorded in changed_diag. All blocks in the same diagonal are merged
 * in the next step.
 */
extern "C" __global__ void clustersIntersecCheck(int *cluster_matrix, int *changed_diag,
                                                 int base_row, int base_column,
                                                 int sub_matrix_row, int sub_matrix_col,
                                                 int sub_matrix_offset_row, int sub_matrix_offset_col,
                                                 int cluster_num)
{
  //Thinking about using % or not
  int col_idx = (blockIdx.x / sub_matrix_col) * sub_matrix_offset_col + (blockIdx.x % sub_matrix_col);
  int row_idx = (blockIdx.x / sub_matrix_row) * sub_matrix_offset_row + (blockIdx.y % sub_matrix_col);

  int col_start = (base_column + col_idx) * blockDim.x;
  int col_end = (col_start + blockDim.x <= cluster_num) ? col_start + blockDim.x : cluster_num;
  int row_start = (base_row + row_idx) * blockDim.x;
  int row_end = (row_start + blockDim.x <= cluster_num) ? row_start + blockDim.x : cluster_num;
  int col = col_start + threadIdx.x;
  int diag_offset = (col_idx > row_idx) ? col_idx - row_idx : col_idx + row_idx;

  if (col < col_end && col_start <= col_end && row_start <= row_end)
  {
    for (int row = row_start; row < row_end; row++)
    {
      if (cluster_matrix[row * cluster_num + col] == 1)
      {
        *changed_diag = diag_offset;
        break;
      }
    }
  }
}

/* Extract clusters of points.
 *
 * This method can handle the case with sparse points (distance between points
 * are larger than threshold), which may lead to infinite loop in the first method.
 */

void GpuEuclideanCluster::extractClusters()
{
  int block_x, grid_x;

  block_x = (size_ > BLOCK_SIZE_X) ? BLOCK_SIZE_X : size_;
  grid_x = (size_ - 1) / block_x + 1;

  int *cluster_offset;
  int cluster_num, old_cluster_num;

  stop_cpu_profiling();
  request_scheduling(17);
  pclEuclideanInitialize << < grid_x, block_x >> > (cluster_indices_, size_);
  checkCudaErrors(cudaDeviceSynchronize());
  stop_profiling(17, LAUNCH);
  start_profiling_cpu_time();

  // #ifdef SLICING
  // int* init_data = (int *)malloc((size_) * sizeof(int));
  // for(int i = 0; i < size_; i++){
  //   init_data[i] = i;    
  // }
  // stop_cpu_profiling();
  // request_scheduling(17);
  // checkCudaErrors(cudaMemcpy(cluster_indices_, init_data, (size_) * sizeof(int), cudaMemcpyHostToDevice));
  // checkCudaErrors(cudaDeviceSynchronize());
  // stop_profiling(17, HTOD);
  // start_profiling_cpu_time();
  // #endif

  old_cluster_num = cluster_num = size_;

  stop_cpu_profiling();
  request_scheduling(18);
  checkCudaErrors(cudaMalloc(&cluster_offset, (size_ + 1) * sizeof(int)));
  checkCudaErrors(cudaMemset(cluster_offset, 0, (size_ + 1) * sizeof(int)));
  stop_profiling(18,HTOD);
  start_profiling_cpu_time();


  stop_cpu_profiling();
  request_scheduling(19);
  blockLabelling << < grid_x, block_x >> > (x_, y_, z_, cluster_indices_, size_, threshold_);
  stop_profiling(19, LAUNCH);
  start_profiling_cpu_time();

  // #ifdef SLICING
  // int slice_cnt = 2;
  // for(int slice_id = 0; slice_id < slice_cnt; slice_id++){
  //   stop_cpu_profiling();
  //   request_scheduling(19);
  //   blockLabelling_with_slicing << < grid_x, block_x >> > (x_, y_, z_, cluster_indices_, size_, threshold_, slice_id, slice_cnt);
  //   stop_profiling(19, LAUNCH);
  //   start_profiling_cpu_time();
  // }
  // #endif
  

  stop_cpu_profiling();
  request_scheduling(20);
  clusterMark << < grid_x, block_x >> > (cluster_indices_, cluster_offset, size_);
  stop_profiling(20, LAUNCH);
  start_profiling_cpu_time();
  exclusiveScan(cluster_offset, size_ + 1, &cluster_num);

  int *cluster_list, *new_cluster_list, *tmp;

  stop_cpu_profiling();
  request_scheduling(21);  
  checkCudaErrors(cudaMalloc(&cluster_list, cluster_num * sizeof(int)));
  stop_profiling(21, HTOD);
  start_profiling_cpu_time();


  #ifndef SLICING
  stop_cpu_profiling();
  request_scheduling(22);
  clusterCollector << < grid_x, block_x >> > (cluster_indices_, cluster_list, cluster_offset, size_);
  checkCudaErrors(cudaDeviceSynchronize());
  stop_profiling(22, LAUNCH);
  start_profiling_cpu_time();
  #endif

  #ifdef SLICING
  // [22] //////////////////////////////////////////////////////////////
  int idx = 0;
  int* h_cluster_indices = (int *)malloc(size_ * sizeof(int));
  
  stop_cpu_profiling();
  request_scheduling(22);
  checkCudaErrors(cudaMemcpy(h_cluster_indices, cluster_indices_, size_/3*sizeof(int), cudaMemcpyDeviceToHost));  
  stop_profiling(22, DTOH);
  start_profiling_cpu_time();

  idx += size_/3;
  stop_cpu_profiling();
  request_scheduling(22);
  checkCudaErrors(cudaMemcpy(&(h_cluster_indices[idx]), &(cluster_indices_[idx]), size_/3*sizeof(int), cudaMemcpyDeviceToHost));  
  stop_profiling(22, DTOH);
  start_profiling_cpu_time();

  idx += size_/3;
  stop_cpu_profiling();
  request_scheduling(22);
  checkCudaErrors(cudaMemcpy(&(h_cluster_indices[idx]), &(cluster_indices_[idx]), (size_/3 + size_%3)*sizeof(int), cudaMemcpyDeviceToHost));  
  stop_profiling(22, DTOH);
  start_profiling_cpu_time();

  int* h_cluster_offset = (int *)malloc((size_ + 1) * sizeof(int));

  idx = 0;
  stop_cpu_profiling();
  request_scheduling(22);
  checkCudaErrors(cudaMemcpy(h_cluster_offset, cluster_offset, (size_+1)/3*sizeof(int), cudaMemcpyDeviceToHost));  
  checkCudaErrors(cudaDeviceSynchronize());
  stop_profiling(22, DTOH);
  start_profiling_cpu_time();

  idx += (size_+1)/3;
  stop_cpu_profiling();
  request_scheduling(22);
  checkCudaErrors(cudaMemcpy(&(h_cluster_offset[idx]), &(cluster_offset[idx]), (size_+1)/3*sizeof(int), cudaMemcpyDeviceToHost));  
  checkCudaErrors(cudaDeviceSynchronize());
  stop_profiling(22, DTOH);
  start_profiling_cpu_time();

  idx += (size_+1)/3;
  stop_cpu_profiling();
  request_scheduling(22);
  checkCudaErrors(cudaMemcpy(&(h_cluster_offset[idx]), &(cluster_offset[idx]), ((size_+1)%3 + (size_+1)/3)*sizeof(int), cudaMemcpyDeviceToHost));  
  checkCudaErrors(cudaDeviceSynchronize());
  stop_profiling(22, DTOH);
  start_profiling_cpu_time();

  
  int* h_cluster_list = (int *)malloc(cluster_num * sizeof(int));
  idx = 0;
  stop_cpu_profiling();
  request_scheduling(22);
  checkCudaErrors(cudaMemcpy(h_cluster_list, cluster_list, cluster_num/3 * sizeof(int), cudaMemcpyDeviceToHost));  
  checkCudaErrors(cudaDeviceSynchronize());
  stop_profiling(22, DTOH);
  start_profiling_cpu_time();

  idx += cluster_num/3;
  stop_cpu_profiling();
  request_scheduling(22);
  checkCudaErrors(cudaMemcpy(&(h_cluster_list[idx]), &(cluster_list[idx]), (cluster_num/3) * sizeof(int), cudaMemcpyDeviceToHost));  
  checkCudaErrors(cudaDeviceSynchronize());
  stop_profiling(22, DTOH);
  start_profiling_cpu_time();

  idx += cluster_num/3;
  stop_cpu_profiling();
  request_scheduling(22);
  checkCudaErrors(cudaMemcpy(&(h_cluster_list[idx]), &(cluster_list[idx]), (cluster_num/3 + cluster_num%3) * sizeof(int), cudaMemcpyDeviceToHost));  
  checkCudaErrors(cudaDeviceSynchronize());
  stop_profiling(22, DTOH);
  start_profiling_cpu_time();
  
  for(int i = 0; i < size_; i++){
    h_cluster_list[h_cluster_offset[h_cluster_indices[i]]] = h_cluster_indices[i];
  }

  idx = 0;
  stop_cpu_profiling();
  request_scheduling(22);
  checkCudaErrors(cudaMemcpy(cluster_list, h_cluster_list, cluster_num/3 * sizeof(int), cudaMemcpyHostToDevice));  
  stop_profiling(22, HTOD);
  start_profiling_cpu_time();

  idx += cluster_num/3;
  stop_cpu_profiling();
  request_scheduling(22);
  checkCudaErrors(cudaMemcpy(&(cluster_list[idx]), &(h_cluster_list[idx]), (cluster_num/3) * sizeof(int), cudaMemcpyHostToDevice));  
  stop_profiling(22, HTOD);
  start_profiling_cpu_time();

  idx += cluster_num/3;
  stop_cpu_profiling();
  request_scheduling(22);
  checkCudaErrors(cudaMemcpy(&(cluster_list[idx]), &(h_cluster_list[idx]), (cluster_num%3 + cluster_num/3 ) * sizeof(int), cudaMemcpyHostToDevice));  
  stop_profiling(22, HTOD);
  start_profiling_cpu_time();

  checkCudaErrors(cudaDeviceSynchronize());
  #endif

  int *cluster_matrix;
  int *new_cluster_matrix;

  stop_cpu_profiling();
  request_scheduling(23);
  checkCudaErrors(cudaMalloc(&cluster_matrix, cluster_num * cluster_num * sizeof(int)));
  stop_profiling(23, HTOD);
  start_profiling_cpu_time();

  stop_cpu_profiling();
  request_scheduling(24);
  checkCudaErrors(cudaMemset(cluster_matrix, 0, cluster_num * cluster_num * sizeof(int)));
  stop_profiling(24, HTOD);
  start_profiling_cpu_time();

  checkCudaErrors(cudaDeviceSynchronize());


  stop_cpu_profiling();  
  request_scheduling(25);
  checkCudaErrors(cudaMalloc(&new_cluster_list, cluster_num * sizeof(int)));
  stop_profiling(25, HTOD);
  start_profiling_cpu_time();

  


  stop_cpu_profiling();
  request_scheduling(26);
  buildClusterMatrix << < grid_x, block_x >> >
                                    (x_, y_, z_, cluster_indices_, cluster_matrix, cluster_offset, size_, cluster_num, threshold_);
  
  stop_profiling(26, LAUNCH);
  start_profiling_cpu_time();
  checkCudaErrors(cudaDeviceSynchronize());
  // [25] ////////////////////////////////////////////////////////////// 
  // slice_cnt = 5;
  // for(int slice_id = 0; slice_id<slice_cnt; slice_id++){
  //   stop_cpu_profiling();
  //   request_scheduling(26);    
  //   buildClusterMatrix_with_slicing << < grid_x, block_x >> > (x_, y_, z_, cluster_indices_, cluster_matrix, cluster_offset, size_, cluster_num, threshold_, slice_id, slice_cnt);
  //   stop_profiling(26, LAUNCH);
  //   start_profiling_cpu_time();
  //   checkCudaErrors(cudaDeviceSynchronize());
  // }
  ///////////////////////////////////////////////////////////////////////

  int block_x2 = 0, grid_x2 = 0;

  bool *changed;
  
  stop_cpu_profiling();
  request_scheduling(27);
  checkCudaErrors(cudaMallocHost(&changed, sizeof(bool)));
  stop_profiling(27, LAUNCH);
  start_profiling_cpu_time();
#ifndef SERIAL
  int *changed_diag;

  stop_cpu_profiling();
  request_scheduling(28);
  checkCudaErrors(cudaMallocHost(&changed_diag, sizeof(int)));
  stop_profiling(28, LAUNCH);
  start_profiling_cpu_time();
#endif

  int max_base_row = 0;

  do
  {
    *changed = false;
    block_x2 = (cluster_num > BLOCK_SIZE_X) ? BLOCK_SIZE_X : cluster_num;
    grid_x2 = (cluster_num - 1) / block_x2 + 1;

    stop_cpu_profiling();
    request_scheduling(29);
    mergeSelfClusters << < grid_x2, block_x2 >> > (cluster_matrix, cluster_list, cluster_num, changed);
    checkCudaErrors(cudaDeviceSynchronize());
    stop_profiling(29, LAUNCH);    
    start_profiling_cpu_time();

    // #ifdef SLICING
    // slice_cnt = 5;
    
    // int row_start_origin = block_x2;
    // int row_end_origin = (row_start_origin + block_x2 <= cluster_num) ? row_start_origin + block_x2 : cluster_num;
    // int quotient = row_start_origin / row_end_origin;
    // int remainder = row_start_origin % row_end_origin;

    // if(block_x2 >= slice_cnt){
    //   for(int slice_id = 0; slice_id < slice_cnt; slice_id++){
    //     int row_start = slice_id*quotient;
    //     int row_end = row_start + quotient;
    //     if((slice_id+1) == slice_cnt) row_end += remainder;
    //     if(row_end > row_end_origin) row_end = row_end_origin;

    //     stop_cpu_profiling();
    //     request_scheduling(29);
    //     mergeSelfClustersWithSlicing << < grid_x2, block_x2 >> > (cluster_matrix, cluster_list, cluster_num, changed, row_start, row_end);
    //     checkCudaErrors(cudaDeviceSynchronize());
    //     stop_profiling(29, LAUNCH);    
    //     start_profiling_cpu_time();
    //   }      
    // }
    // else{
    //   stop_cpu_profiling();
    //   request_scheduling(29);
    //   mergeSelfClusters << < grid_x2, block_x2 >> > (cluster_matrix, cluster_list, cluster_num, changed);
    //   checkCudaErrors(cudaDeviceSynchronize());
    //   stop_profiling(29, LAUNCH);    
    //   start_profiling_cpu_time();
    // }
    // #endif

    int base_row = 1, base_column = 0;
    int sub_matrix_offset_row = 2, sub_matrix_offset_col = 2;
    int sub_matrix_row = 1, sub_matrix_col = 1;
    int sub_matrix_num;
    int max_rows = grid_x2;

    max_base_row = base_row;

    while (!(*changed) && cluster_num > BLOCK_SIZE_X && base_row * BLOCK_SIZE_X < cluster_num &&
           base_column < cluster_num)
    {

      sub_matrix_num = (cluster_num - base_row - 1) / sub_matrix_offset_row + 1;
      block_x2 = BLOCK_SIZE_X;
      grid_x2 = sub_matrix_num * sub_matrix_col;

#ifdef SERIAL
      //Merge clusters in each sub-matrix by moving from top to bottom of the similarity sub-matrix
      for (int shift_level = 0; !(*changed) && shift_level < sub_matrix_col; shift_level++) {
        stop_cpu_profiling();
        request_scheduling(30);
        mergeInterClusters<<<grid_x2, block_x2>>>(cluster_matrix, cluster_list,
                                shift_level,
                                base_row, base_column,
                                sub_matrix_row, sub_matrix_col,
                                sub_matrix_offset_row, sub_matrix_offset_col,
                                cluster_num, changed);
        stop_profiling(30, LAUNCH);
        start_profiling_cpu_time();
        checkCudaErrors(cudaDeviceSynchronize());
      }
#else
      int grid_y2 = sub_matrix_row;

      dim3 block_size(block_x2, 1, 1);
      dim3 grid_size(grid_x2, grid_y2, 1);

      *changed_diag = -1;
      stop_cpu_profiling();
      request_scheduling(31);
      clustersIntersecCheck << < grid_size, block_size >> > (cluster_matrix, changed_diag,
        base_row, base_column,
        sub_matrix_row, sub_matrix_col,
        sub_matrix_offset_row, sub_matrix_offset_col,
        cluster_num);      
      stop_profiling(31, LAUNCH);
      checkCudaErrors(cudaDeviceSynchronize());
      start_profiling_cpu_time();

      if (*changed_diag > 0)
      {
        //Merge clusters in sub-matrix that stay in the changed_diag diagonal by moving from top to bottom of the matrix.
        stop_cpu_profiling();
        request_scheduling(32);
        mergeInterClusters << < grid_x2, block_x2 >> > (cluster_matrix, cluster_list, *changed_diag,
          base_row, base_column,
          sub_matrix_row, sub_matrix_col,
          sub_matrix_offset_row, sub_matrix_offset_col,
          cluster_num, changed);
        stop_profiling(32, LAUNCH);
        start_profiling_cpu_time();
        checkCudaErrors(cudaDeviceSynchronize());
      }

#endif
      base_row += sub_matrix_row;
      sub_matrix_row = (sub_matrix_row * 2 + base_row < max_rows) ? sub_matrix_row * 2 : max_rows - base_row;
      sub_matrix_col *= 2;
      sub_matrix_offset_row *= 2;
      sub_matrix_offset_col *= 2;
    }

    max_base_row = base_row;

    if (*changed)
    {
      stop_cpu_profiling();
      request_scheduling(33);
      reflexClusterChanges << < grid_x, block_x >> > (cluster_indices_, cluster_offset, cluster_list, size_);      
      stop_profiling(33, LAUNCH);
      start_profiling_cpu_time();
      
      stop_cpu_profiling();
      request_scheduling(34);
      checkCudaErrors(cudaMemset(cluster_offset, 0, (size_ + 1) * sizeof(int)));
      stop_profiling(34, HTOD);
      start_profiling_cpu_time();

      block_x2 = (cluster_num > BLOCK_SIZE_X) ? BLOCK_SIZE_X : cluster_num;
      grid_x2 = (cluster_num - 1) / block_x2 + 1;

      stop_cpu_profiling();
      request_scheduling(35);
      clusterMark << < grid_x2, block_x2 >> > (cluster_list, cluster_offset, cluster_num);
      stop_profiling(35, LAUNCH);
      start_profiling_cpu_time();

      old_cluster_num = cluster_num;
      exclusiveScan(cluster_offset, size_ + 1, &cluster_num);

      stop_cpu_profiling();
      request_scheduling(36);
      clusterCollector << < grid_x2, block_x2 >> > (cluster_list, new_cluster_list, cluster_offset, old_cluster_num);
      
      stop_profiling(36, LAUNCH);
      start_profiling_cpu_time();
      checkCudaErrors(cudaDeviceSynchronize());

      checkCudaErrors(cudaMalloc(&new_cluster_matrix, cluster_num * cluster_num * sizeof(int)));

      stop_cpu_profiling();
      request_scheduling(37);
      checkCudaErrors(cudaMemset(new_cluster_matrix, 0, cluster_num * cluster_num * sizeof(int)));
      stop_profiling(37, HTOD);
      start_profiling_cpu_time();

      stop_cpu_profiling();
      request_scheduling(38);
      rebuildClusterMatrix << < grid_x2, block_x2 >> >
                                         (cluster_matrix, cluster_list, new_cluster_matrix, cluster_offset, old_cluster_num, cluster_num);
      
      stop_profiling(38, LAUNCH);
      start_profiling_cpu_time();
      checkCudaErrors(cudaDeviceSynchronize());

      stop_cpu_profiling();
      request_scheduling(39);
      checkCudaErrors(cudaFree(cluster_matrix));
      stop_profiling(39, HTOD);
      start_profiling_cpu_time();

      cluster_matrix = new_cluster_matrix;
      tmp = cluster_list;
      cluster_list = new_cluster_list;
      new_cluster_list = tmp;
    }
  } while (*changed && max_base_row < cluster_num);

  cluster_num_ = cluster_num;

  //Reset all cluster indexes to make them start from 0
  stop_cpu_profiling();
  request_scheduling(40);
  resetClusterIndexes << < grid_x, block_x >> > (cluster_indices_, cluster_offset, size_);  
  stop_profiling(40, LAUNCH);
  start_profiling_cpu_time();
  checkCudaErrors(cudaDeviceSynchronize());  

  stop_cpu_profiling();
  request_scheduling(41);
  checkCudaErrors(cudaMemcpy(cluster_indices_host_, cluster_indices_, size_ * sizeof(int), cudaMemcpyDeviceToHost));
  stop_profiling(41, DTOH);
  start_profiling_cpu_time();

  // slice_cnt = 3;
  // int quotient = size_/slice_cnt;
  // int remainder = size_%slice_cnt;
  // for(int slice_id = 0; slice_id < slice_cnt; slice_id++){
  //   int start_idx = slice_id * quotient;
  //   int size = 

  //   stop_cpu_profiling();
  //   request_scheduling(36);

  //   stop_profiling(36, DTOH);
  //   start_profiling_cpu_time();
  // }


  /////////////////////////////////////////////////////////////////// 

  stop_cpu_profiling();
  request_scheduling(42);
  checkCudaErrors(cudaFree(cluster_matrix));
  stop_profiling(42, DTOH);
  start_profiling_cpu_time();

  stop_cpu_profiling();
  request_scheduling(43);
  checkCudaErrors(cudaFree(cluster_list));
  stop_profiling(43, DTOH);
  start_profiling_cpu_time();

  stop_cpu_profiling();
  request_scheduling(44);
  checkCudaErrors(cudaFree(new_cluster_list));
  stop_profiling(44, DTOH);
  start_profiling_cpu_time();

  stop_cpu_profiling();
  request_scheduling(45);
  checkCudaErrors(cudaFree(cluster_offset));
  stop_profiling(45, DTOH);
  start_profiling_cpu_time();

  stop_cpu_profiling();
  request_scheduling(46);
  checkCudaErrors(cudaFreeHost(changed));
  stop_profiling(46, DTOH);
  start_profiling_cpu_time();
#ifndef SERIAL
  stop_cpu_profiling();
  request_scheduling(47);
  checkCudaErrors(cudaFreeHost(changed_diag));
  stop_profiling(47, DTOH);
  start_profiling_cpu_time();
#endif
}

/* Collect points that belong to same clusters and put them together.
 *
 * The output is a vector whose each element contains indexes of points
 * that belong to a same clusters.
 */
std::vector <GpuEuclideanCluster::GClusterIndex> GpuEuclideanCluster::getOutput()
{
  std::vector <GClusterIndex> cluster_indices(cluster_num_);

  for (unsigned int i = 0; i < cluster_indices.size(); i++)
    cluster_indices[i].index_value = -1;

  for (int i = 0; i < size_; i++)
  {
    cluster_indices[cluster_indices_host_[i]].points_in_cluster.push_back(i);
    cluster_indices[cluster_indices_host_[i]].index_value = cluster_indices_host_[i];
  }

  for (unsigned int i = 0; i < cluster_indices.size();)
  {
    int number_of_pts = cluster_indices[i].points_in_cluster.size();

    if (number_of_pts < min_cluster_pts_ || number_of_pts > max_cluster_pts_)
      cluster_indices.erase(cluster_indices.begin() + i);
    else
      i++;
  }

  return cluster_indices;
}

/* Generate sparse points.
 * The number of points is fixed at 10000.
 * Cannot afford more (e.g. 100 000 points) since
 * GPU memory is not enough for a matrix with 10 billions cells.
 */
GpuEuclideanCluster::SamplePointListXYZ GpuEuclideanCluster::generateSample()
{
  GpuEuclideanCluster::SamplePointListXYZ output;

  output.size = 10000;

  output.x = (float *) malloc(sizeof(float) * output.size);
  output.y = (float *) malloc(sizeof(float) * output.size);
  output.z = (float *) malloc(sizeof(float) * output.size);

  output.x[0] = 0;
  output.y[0] = 0;
  output.z[0] = 0;

  for (int i = 1; i < output.size; i++)
  {
    output.x[i] = (i % 3 == 0) ? output.x[i - 1] + threshold_ + 1 : output.x[i - 1];
    output.y[i] = (i % 3 == 1) ? output.y[i - 1] + threshold_ + 1 : output.y[i - 1];
    output.z[i] = (i % 3 == 2) ? output.z[i - 1] + threshold_ + 1 : output.z[i - 1];
  }

  return output;
}

GpuEuclideanCluster::~GpuEuclideanCluster()
{
  checkCudaErrors(cudaFree(x_));
  checkCudaErrors(cudaFree(y_));
  checkCudaErrors(cudaFree(z_));
  checkCudaErrors(cudaFree(cluster_indices_));
  free(cluster_indices_host_);
}


/* GPU Profiling */
void start_profiling_execution_time(){
	if(GPU_PROFILING == 1)
		cudaEventRecord(e_event_start, 0);
}

void start_profiling_response_time(){
	if(GPU_PROFILING == 1)
		cudaEventRecord(r_event_start, 0);
}

void start_profiling_cpu_time(){
  if(GPU_PROFILING == 1){
    cpu_id++;
		gettimeofday(&startTime, NULL);
  }
}

void stop_profiling(int id, int type){
	if(GPU_PROFILING == 1){		
		float e_time, r_time;
    char gpu_id_buf[BUFFER_SIZE];
    if(gpu_scheduling_flag_==1){
        sched_info_->scheduling_flag = 0;
        sched_info_->state = NONE;
    }

		cudaEventRecord(e_event_stop, 0);
    cudaEventRecord(r_event_stop, 0);
		cudaEventSynchronize(e_event_stop);
    cudaEventSynchronize(r_event_stop);
		cudaEventElapsedTime(&e_time, e_event_start, e_event_stop);
    cudaEventElapsedTime(&r_time, r_event_start, r_event_stop);
    e_time = MS2US(e_time);
    r_time = MS2US(r_time);
		// write_data(gid, time, type);
    sprintf(gpu_id_buf,"g%d",id);

    //write_profiling_data(id, e_time, r_time, type);

    write_profiling_data(gpu_id_buf, e_time, r_time, type);
		// gid++;
	}
}

void stop_cpu_profiling(){
  if(GPU_PROFILING == 1){
    long long int elapsedTime;
    char cpu_id_buf[BUFFER_SIZE];

    gettimeofday(&endTime, NULL);
    elapsedTime = ((long long int)(endTime.tv_sec - startTime.tv_sec)) * 1000000ll + (endTime.tv_usec - startTime.tv_usec);

    sprintf(cpu_id_buf,"e%d",cpu_id);
    write_cpu_profiling_data(cpu_id_buf,elapsedTime);    
  }
}

void write_profiling_data(const char* id, float e_time, float r_time, int type){
	if(GPU_PROFILING == 1){
		fprintf(execution_time_fp, "%s, %f, %d\n", id, e_time, type);	
    fprintf(response_time_fp, "%s, %f, %d\n", id, r_time, type);	
    fprintf(remain_time_fp, "%s, %llu\n", id, absolute_deadline_ - get_current_time_us());
	}
}

void write_cpu_profiling_data(const char *id, long long int c_time){
  if(GPU_PROFILING == 1){
		fprintf(execution_time_fp, "%s, %02d\n", id, c_time);	
    fprintf(response_time_fp, "%s, %02d\n", id, c_time);    
	}
}


void write_dummy_line(){
	if(GPU_PROFILING == 1){  
    fprintf(execution_time_fp, "-1, -1, -1\n");						
		fflush(execution_time_fp);
		fprintf(response_time_fp, "-1, -1, -1\n");						
		fflush(response_time_fp);
    fprintf(remain_time_fp, "-1, -1\n");						
		fflush(remain_time_fp);
    cpu_id = 0;
	}
}

void initialize_file(const char execution_time_filename[], const char response_time_filename[], const char remain_time_filename[]){
	if(GPU_PROFILING == 1){
		execution_time_fp = fopen(execution_time_filename, "w+");
		fprintf(execution_time_fp, "ID, TIME, TYPE\n");
    response_time_fp = fopen(response_time_filename, "w+");
		fprintf(response_time_fp, "ID, TIME, TYPE\n");
    remain_time_fp = fopen(remain_time_filename, "w+");
    fprintf(remain_time_fp, "ID, TIME\n");
	}
}

void close_file(){
	if(GPU_PROFILING == 1){
		fclose(execution_time_fp);
    fclose(response_time_fp);
    fclose(remain_time_fp);
  }
}

void sig_handler(int signum){
  if(signum == SIGUSR1 || signum == SIGUSR2){
    is_scheduled_ = 1;
    return;    
  }
  else
      termination();    
}

void termination(){
	if(gpu_scheduling_flag_==1){
		sched_info_->state = STOP;
  	shmdt(sched_info_);
	}
  
  if(remove(task_filename_)){
      printf("Cannot remove file %s\n", task_filename_);
      exit(1);
  }
  exit(0);
}

unsigned long long get_current_time_us(){
  struct timespec ts;
  unsigned long long current_time;
  clock_gettime(CLOCK_REALTIME, &ts);
  current_time = ts.tv_sec%10000 * 1000000 + ts.tv_nsec/1000;
  return current_time;
}

void us_sleep(unsigned long long us){
  struct timespec ts;
  ts.tv_sec = us/1000000;
  ts.tv_nsec = us%1000000*1000;
  nanosleep(&ts, NULL);
  return;
}

void initialize_signal_handler(){
  signal(SIGINT, sig_handler);
  signal(SIGTSTP, sig_handler);
  signal(SIGQUIT, sig_handler);
  signal(SIGUSR1, sig_handler);
  signal(SIGUSR2, sig_handler);
}

void create_task_file(){        
  FILE* task_fp;
  task_fp = fopen(task_filename_, "w");
  if(task_fp == NULL){
      printf("Cannot create task file at %s\n", task_filename_);
      exit(1);
  }
  fprintf(task_fp, "%d\n", getpid());
  fprintf(task_fp, "%d", key_id_);
  fclose(task_fp);
}

void get_scheduler_pid(){
  FILE* scheduler_fp;
  printf("Wait the scheduler...\n");
  while(1){
      scheduler_fp = fopen("/tmp/np_edf_scheduler", "r");
      if(scheduler_fp) break;
  }
  while(1){
      fscanf(scheduler_fp, "%d", &scheduler_pid_);
      if(scheduler_pid_ != 0) break;
  }
  printf("Scheduler pid: %d\n", scheduler_pid_);
  fclose(scheduler_fp);
}

void initialize_sched_info(){
	if(gpu_scheduling_flag_!=1) return;
  FILE* sm_key_fp;
  sm_key_fp = fopen("/tmp/sm_key", "r");
  if(sm_key_fp == NULL){
      printf("Cannot open /tmp/sm_key\n");
      termination();
  }

  key_ = ftok("/tmp/sm_key", key_id_);
  shmid_ = shmget(key_, sizeof(SchedInfo), 0666|IPC_CREAT);
  sched_info_ = (SchedInfo*)shmat(shmid_, 0, 0);
  sched_info_->pid = getpid();
  sched_info_->state = NONE;
  sched_info_->scheduling_flag = 0;
}

void init_scheduling(char* task_filename, const char* deadline_filename, int key_id){
	if(gpu_scheduling_flag_!=1) return;
  // Get deadline list
  get_deadline_list(deadline_filename);
  // Initialize key id for shared memory
  key_id_ = key_id;

  // Initialize signal handler
  initialize_signal_handler();

  // Create task file
  sprintf(task_filename_, "%s", task_filename);
  create_task_file();    
  // Get scheduler pid
  get_scheduler_pid();

  // Initialize scheduling information (shared memory data)
  initialize_sched_info();

  sigemptyset(&sigset_);
  sigaddset(&sigset_, SIGUSR1);
  sigaddset(&sigset_, SIGUSR2);
  sigprocmask(SIG_BLOCK, &sigset_, NULL);    

  // sigwait(&sigset_, &sig_);    
  // kill(scheduler_pid_, SIGUSR2);
  // sigprocmask(SIG_UNBLOCK, &sigset_, NULL);
  
  printf("Task [%d] is ready to work\n", getpid());
  // sigaddset(&sigset_, SIGUSR1);
  // sigprocmask(SIG_BLOCK, &sigset_, NULL);    

}

void request_scheduling(int id){  
  if(gpu_scheduling_flag_ == 1){
		unsigned long long relative_deadline = deadline_list_[id];  
		if(identical_deadline_ != 0) sched_info_->deadline = absolute_deadline_;  
		else sched_info_->deadline = get_current_time_us() + relative_deadline;  

		sched_info_->state = WAIT;        
		// printf("Request schedule - deadline: %llu\n", sched_info_->deadline);
  }

  start_profiling_response_time();

  if(gpu_scheduling_flag_ == 1){
		while(1){
			kill(scheduler_pid_, SIGUSR1);
			// if(!sigwait(&sigset_, &sig_)) break;
			// if(is_scheduled_ == 1) break;
			if(sched_info_->scheduling_flag == 1) break;
		}  
  }

  start_profiling_execution_time();

  if(gpu_scheduling_flag_==1){
		sched_info_->state = RUN;
		sched_info_->deadline = 0;
	}
}

void get_deadline_list(const char* filename){
  FILE* fp;
  fp = fopen(filename, "r");
  if(fp==NULL){
	  fprintf(stderr, "Cannot find file %s\n", filename);
	  exit(1);
  }
  char buf[1024];
  long long int deadline;
  for(int i = 0; i < sizeof(deadline_list_)/sizeof(long long int); i++){
    fgets(buf, 1024, fp);
    strtok(buf, "\n");
    sscanf(buf, "%*s, %llu", &deadline);
    deadline_list_[i] = deadline;
  }
}

void set_identical_deadline(unsigned long long identical_deadline){
  identical_deadline_ = identical_deadline;
}

void set_absolute_deadline(){  
  absolute_deadline_ = get_current_time_us() + identical_deadline_;
}

void set_slicing_flag(int flag){
  slicing_flag_ = flag;
}

void set_gpu_scheduling_flag(int gpu_scheduling_flag){
	gpu_scheduling_flag_ = gpu_scheduling_flag;
}