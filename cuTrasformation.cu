#include "cuTrasformation.cuh"
#include <math.h>
#include <stdio.h>
#include "cuMatrix.h"
#include "util.h"
#include "cuda_runtime.h"
#include <curand_kernel.h>
#include <time.h>
#include "Config.h"
#include <helper_functions.h>
#include <helper_cuda.h>

#define GAUSSIAN_FIELD_SIZE (21) // strictly odd number
curandGenerator_t rand_generator_device;
const curandRngType_t generator_type = CURAND_RNG_PSEUDO_DEFAULT;

cuMatrix<double>* cuGaussianKernel;
cuMatrix<double>* cuDispH;
cuMatrix<double>* cuDispV;

float * cu_d_randonNumf;
double* cu_d_randomNum;
double* cu_h_randomNum;
double dElasticSigma   = 4.0;   // higher numbers are more smooth and less distorted; Simard uses 4.0


int getRandomNumLen(int batch, int ImgSize)
{
	return batch * ImgSize * ImgSize * 2;
}

/*
函数功能：建立高斯滤波
线程分配<<<dim3(1),dim3(GAUSSIAN_FIELD_SIZE*GAUSSIAN_FIELD_SIZE)>>>
*/
__global__ void g_createGaussianKernel(double* gaussian, double dElasticSigma, int ImgSize)
{
	int iiMid = GAUSSIAN_FIELD_SIZE >> 1;
	double doubleElasticSigma = dElasticSigma * dElasticSigma;
	int row = threadIdx.x % ImgSize;
	int col = threadIdx.x / ImgSize;
	double val1 = 1.0 / (dElasticSigma * 2.0 * 3.1415926535897932384626433832795);
	double val2 = (row-iiMid)*(row-iiMid) + (col-iiMid)*(col-iiMid);

	gaussian[threadIdx.x] = val1 * exp(-1.0 * val2 / (2.0 * doubleElasticSigma));
}

void cuInitDistortionMemery(int batch, int ImgSize)
{
	curandStatus_t curandstatus;
	cudaError_t cuStatus;
	cuGaussianKernel = new cuMatrix<double>(GAUSSIAN_FIELD_SIZE, GAUSSIAN_FIELD_SIZE, 1);
	if(GAUSSIAN_FIELD_SIZE * GAUSSIAN_FIELD_SIZE > MAX_THREADS)
	{
		printf("g_createGaussianKernel > MAX_THREADS\n");
		exit(0);
	}
	g_createGaussianKernel<<<dim3(1),dim3(GAUSSIAN_FIELD_SIZE * GAUSSIAN_FIELD_SIZE)>>>(
		cuGaussianKernel->devData,
		dElasticSigma,
		ImgSize);
	cudaDeviceSynchronize();

	//cu_d_randomNum
	cuStatus = cudaMalloc((void**)&cu_d_randomNum, sizeof(double) * getRandomNumLen(batch, ImgSize));
	if(cuStatus != CUDA_SUCCESS)
	{
		printf("cudaMalloc cu_d_randomNum fail\n");
		exit(0);
	}

	//cu_d_randonNumf
	cuStatus = cudaMalloc((void**)&cu_d_randonNumf, sizeof(float) * getRandomNumLen(batch, ImgSize));
	if(cuStatus != CUDA_SUCCESS)
	{
		printf("cudaMalloc cu_d_randomNumf fail\n");
		exit(0);
	}

	//cu_h_randomNum
	cu_h_randomNum = (double*)malloc(sizeof(double) * getRandomNumLen(batch, ImgSize));
	if(!cu_h_randomNum)
	{
		printf("malloc cu_h_randomNum fail\n");
	}

	//curandCreateGenerator

	curandstatus = curandCreateGenerator(&rand_generator_device, generator_type);
	if(curandstatus != CURAND_STATUS_SUCCESS)
	{
		printf("curandCreateGenerator fail\n");
		exit(0);
	}

	cuDispV = new cuMatrix<double>(batch, ImgSize * ImgSize, 1);
	cuDispH = new cuMatrix<double>(batch, ImgSize * ImgSize, 1);
}


__global__ void g_getRandomUniform(float* r1, double* r2, int len)
{
	for(int i = 0; i < len; i += gridDim.x * blockDim.x)
	{
		int id = i + blockDim.x * blockIdx.x + threadIdx.x;
		if(id < len)
		{
			r2[id] = r1[id] * 2.0f - 1.0f;
		}
	}
}

/*线程分配：dim3(batch),dim3(ImgSize,ImgSize)*/
__global__ void g_generateDistortionMap(
	double* _dispH,
	double* _dispV,
	double* rand, 
	double* gaussianKernel,
	double dElasticScaling, 
	double dMaxScaling,
	double dMaxRotation,
	int ImgSize)
{
	int ImgSize2 = ImgSize * ImgSize;

	double* uniformH = rand + blockIdx.x * ImgSize2;
	double* uniformV = rand + blockIdx.x * ImgSize2 * 2;
	double* dispH = _dispH + ImgSize2 * blockIdx.x;
	double* dispV = _dispV + ImgSize2 * blockIdx.x;

	for(int is = 0; is < ImgSize2; is += blockDim.x)
	{
		int idx = is + threadIdx.x;
		if(idx < ImgSize2)
		{
			int row = idx / ImgSize;
			int col = idx % ImgSize;

			int iiMid = GAUSSIAN_FIELD_SIZE / 2;

			double fConvolvedH = 0.0;
			double fConvolvedV = 0.0;
			double fSampleH, fSampleV;

			double elasticScale = dElasticScaling;

			for(int xxx = 0; xxx < GAUSSIAN_FIELD_SIZE; ++xxx)
			{
				for(int yyy = 0; yyy < GAUSSIAN_FIELD_SIZE; ++yyy)
				{
					int xxxDisp = col - iiMid + xxx;
					int yyyDisp = row - iiMid + yyy;

					if(xxxDisp < 0 || xxxDisp >= ImgSize || 
						yyyDisp < 0 || yyyDisp >= ImgSize)
					{
						fSampleH = 0.0;
						fSampleV = 0.0;
					}
					else 
					{
						fSampleH = uniformH[yyyDisp * ImgSize + xxxDisp];
						fSampleV = uniformV[yyyDisp * ImgSize + xxxDisp];
					}


					fConvolvedH += fSampleH * gaussianKernel[yyy * GAUSSIAN_FIELD_SIZE + xxx];
					fConvolvedV += fSampleV * gaussianKernel[yyy * GAUSSIAN_FIELD_SIZE + xxx];
				}
			}

			dispH[row * ImgSize + col] = elasticScale * fConvolvedH;
			dispV[row * ImgSize + col] = elasticScale * fConvolvedV;

			__syncthreads();

			double dSFHoriz = dMaxScaling / 100.0 * rand[blockIdx.x];
			double dSFVert  = dMaxScaling / 100.0 * rand[blockIdx.x + 1];

			int iMid = ImgSize / 2;

			dispH[row * ImgSize + col] += dSFHoriz * (col - iMid);
			dispV[row * ImgSize + col] += dSFVert  * (row - iMid);

			__syncthreads();

			double angle = dMaxRotation * rand[blockIdx.x];
			angle = angle * 3.1415926535897932384626433832795 / 180.0;

			double cosAngle = cos(angle);
			double sinAngle = sin(angle);

			double xx = row - iMid;
			double yy = col - iMid;

			dispH[row * ImgSize + col] += yy - yy * cosAngle - xx * sinAngle;
			dispV[row * ImgSize + col] += xx - xx * cosAngle + yy * sinAngle;
		}
	}
}

/*线程分配：dim3(batch, channels),dim3(512)*/
__global__ void g_applyDistortionMap(
	double** _inputs,
	double** _outputs,
	double* _dispH, 
	double* _dispV, 
	int ImgSize)
{
	int c = blockIdx.y;

	int ImgSize2 = ImgSize * ImgSize;
	double* input = _inputs[blockIdx.x] + ImgSize2 * c;
	double* output= _outputs[blockIdx.x]+ ImgSize2 * c;
	double* dispV = _dispV + blockIdx.x * ImgSize2;
	double* dispH = _dispH + blockIdx.x * ImgSize2;

	for(int is = 0; is < ImgSize2; is += blockDim.x)
	{
		int idx = is + threadIdx.x;
		if(idx < ImgSize2)
		{
			int row = idx / ImgSize;
			int col = idx % ImgSize;

			double sourceRow, sourceCol;
			double fracRow, fracCol;
			double w1, w2, w3, w4;
			double sourceValue;
			int sRow, sCol, sRowp1, sColp1;
			bool bSkipOutOfBounds;

			sourceRow = (double)row - dispV[row * ImgSize + col];
			sourceCol = (double)col - dispH[row * ImgSize + col];

			fracRow = sourceRow - (int)sourceRow;
			fracCol = sourceCol - (int)sourceCol;

			w1 = ( 1.0 - fracRow ) * ( 1.0 - fracCol );
			w2 = ( 1.0 - fracRow ) * fracCol;
			w3 = fracRow * ( 1.0 - fracCol );
			w4 = fracRow * fracCol;

			bSkipOutOfBounds = false;

			if ( ((int)sourceRow + 1) >= ImgSize )	bSkipOutOfBounds = true;
			if ( (int)sourceRow < 0 )				bSkipOutOfBounds = true;

			if ( ((int)sourceCol + 1) >= ImgSize )	bSkipOutOfBounds = true;
			if ( (int)sourceCol < 0 )				bSkipOutOfBounds = true;

			if ( bSkipOutOfBounds == false )
			{
				sRow = (int)sourceRow;
				sCol = (int)sourceCol;

				sRowp1 = sRow + 1;
				sColp1 = sCol + 1;

				while (sRowp1 >= ImgSize ) sRowp1 -= ImgSize;
				while (sRowp1 < 0 ) sRowp1 += ImgSize;

				while (sColp1 >= ImgSize ) sColp1 -= ImgSize;
				while (sColp1 < 0 ) sColp1 += ImgSize;

				sourceValue =	
					w1 * input[sRow   * ImgSize + sCol] +
					w2 * input[sRow   * ImgSize + sColp1] +
					w3 * input[sRowp1 * ImgSize + sCol] +
					w4 * input[sRowp1 * ImgSize + sColp1];
			}
			else
			{
				sourceValue = -1.0;  
			}
			output[row * ImgSize + col] = sourceValue;
		}
	}

}

void cuApplyRandom(int batch, unsigned long long s, int ImgSize)
{
	curandStatus_t curandStatus;
	cudaError_t cudasSatus;
	unsigned long long seed = s;
	curandStatus = curandSetPseudoRandomGeneratorSeed(rand_generator_device, seed);

	if(curandStatus != CURAND_STATUS_SUCCESS)
	{
		printf("curandSetPseudoRandomGeneratorSeed fail\n");
		exit(0);
	}

	curandGenerateUniform(rand_generator_device, cu_d_randonNumf, getRandomNumLen(batch, ImgSize));

	g_getRandomUniform<<<dim3(256),dim3(256)>>>(cu_d_randonNumf, cu_d_randomNum, getRandomNumLen(batch, ImgSize));
	cudaDeviceSynchronize();
	getLastCudaError("g_getRandomUniform");

	g_generateDistortionMap<<<dim3(batch),dim3(512)>>>(cuDispH->devData,
		cuDispV->devData, cu_d_randomNum, cuGaussianKernel->devData,
		Config::instance()->getDistortion(),
		Config::instance()->getScale(),
		Config::instance()->getRotation(), ImgSize);
	cudaDeviceSynchronize();
	getLastCudaError("g_generateDistortionMap");

}

void cuApplyDistortion(double**inputs, double**outputs, int batch, int ImgSize)
{
	int threadidx = min(ImgSize * ImgSize, 512);
	g_applyDistortionMap<<<dim3(batch, Config::instance()->getChannels()),
		dim3(threadidx)>>>(inputs,
		outputs, 
		cuDispH->devData,
		cuDispV->devData,
		ImgSize);
	cudaDeviceSynchronize();
	getLastCudaError("g_applyDistortionMap");
}

/*线程安排<<<dim3(batch, channels),dim3(ImgSize,ImgSize)>>>*/
__global__ void g_applyCropMap(double**_inputs, double**_outputs, double* random, double crop, int ImgSize)
{
	int c = blockIdx.y;
	int ImgSize2 = ImgSize * ImgSize;
	double* input = _inputs[blockIdx.x] + c * ImgSize2;
	double* output= _outputs[blockIdx.x]+ c * ImgSize2;

	int sx =(int)(((random[blockIdx.x]     + 1.0) / 2.0 * crop) + 0.499999);
	int sy =(int)(((random[blockIdx.x + 1] + 1.0) / 2.0 * crop) + 0.499999);
	int ex = sx + ImgSize - 1 - crop;
	int ey = sy + ImgSize - 1 - crop;
	for(int is = 0; is < ImgSize2; is += blockDim.x)
	{
		int idx = is + threadIdx.x;
		if(idx < ImgSize2)
		{
			int x  = idx / ImgSize;
			int y  = idx % ImgSize;
			if(x >= sx && x <= ex && y >=sy && y <= ey)
			{
				output[idx] = input[idx];
			}
			else
			{
				output[idx] = -1.0;
			}
		}
	}
}

void cuApplyCrop(double**inputs, double**outputs, int batch, int ImgSize)
{
	g_applyCropMap<<<dim3(batch, Config::instance()->getChannels()),
		dim3(512)>>>(inputs, outputs, cu_d_randomNum, Config::instance()->getCrop(), ImgSize);
	cudaDeviceSynchronize();
	getLastCudaError("g_applyCropMap");
}