#include "calc.h"

#include <cooperative_groups.h>
using namespace cooperative_groups;

#define gpuErrchk(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true)
{
   if (code != cudaSuccess) 
   {
      fprintf(stderr,"GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}

__global__ void movingAvg(int n, int numDays, double* in, double* out){
	int i = blockIdx.x*blockDim.x + threadIdx.x;
	if(i<n){
		out[i] = 0;
		
		if(i>=numDays-1){
			for(int j = i-numDays+1; j <= i; j++){
				out[i] += in[j];
				// if(i==numDays-1)
					// printf("%d %f %f\n", i, in[j], out[i]);
			}
			out[i] /= numDays;
		}
	}
}

__global__ void deltas(int n, double* in, double* out){
	int i = blockIdx.x*blockDim.x+threadIdx.x;
	if(i<n){
		if(i==0) out[i] = 0;
		else{
			out[i] = in[i] - in[i-1];
		}
	}
}

__global__ void stdDev(int n, int period, double* x, double* std){
	int i = blockIdx.x*blockDim.x+threadIdx.x;
	if(i <= period){
		std[i] = 0;
	}
	if(i < n && i > period){
		double average = 0;
		for(int j = i-period+1; j <= i; j++){
			average += x[j];
		}
		average /= period;
		double deviation = 0;
		for(int j = i-period+1; j <= i; j++){
			deviation += (x[j] - average) * (x[j] - average);
		}
		deviation /= period;
		std[i] = __dsqrt_rn(deviation);
		// 
	}
	// if(i==n)
	// 	for(int j = 0; j < n; j++)
	// 		printf("%d %f\n", j, std[j]);
}

__global__ void normalize(int* n, double* ave, double* in){
	// auto g = this_grid();
	int i = blockIdx.x*blockDim.x+threadIdx.x;
	// if(i == 0)
	// 	for(int j = 0; j < n; j++)
	// 		printf("%d %f\n", j, in[j]);
	// __syncthreads();
	// if(i == n)
	// 	for(int j = 0; j < n; j++)
	// 		printf("%d %f\n", j, in[j]);
	// // // if(i<n)
	// // // 	printf("%d %f\n", i, in[i]);
	// __syncthreads();
	if(i == *n){
		// printf("%p\n", in);
		*ave = 0;
		for(int j = 0; j < *n; j++){
			// printf("%d %p %f %f\n", j, ave, *ave, *(in+j));
			// printf("%d %f\n", j, in[j]);
			(*ave) = (*ave) + in[j];
		}
		(*ave) = (*ave) / *n;
		// printf("%i\n", g.size());
	}

	__syncthreads();

	// g.sync();

	if(i < *n){
		// printf("%d %f\n", i, *ave);
		in[i] /= (*ave);
	}
}

__global__ void pearson(int nx, double* x, int* xDates, int ny, double* y, int* yDates, double* r, double* num, double* Xden, double* Yden, double* aveX, double* aveY){
	int i = blockIdx.x*blockDim.x+threadIdx.x;
	auto g = this_grid();
	// __shared__ double aveX;
	// __shared__ double aveY;

	if(i==nx){
		double sumX = 0, sumY = 0;
		for(int j = 0; j < nx; j++){
			sumX += x[j];
		}
		for(int j = 0; j < ny; j++){
			sumY += y[j];
		}
		*aveX = sumX/nx;
		*aveY = sumY/ny;
		// __shared__ double num[n];
		// __shared__ double Xden[n];
		// __shared__ double Yden[n];
		// printf("%f %f\n", aveX, aveY);
	}

	// __syncthreads();
	g.sync();
	if(i<nx){
		// printf("%s %d %d %d\n", "cuda", i, nx, ny);
		int j;
		for(j = 0; j < ny; j++){
			if(xDates[i] > yDates[j] && xDates[i] < yDates[j+1]){
				break;
			}
		}
		// printf("%d %d %d %d\n", i, xDates[i], yDates[j], j);
		// printf("%f %f\n", x[i], y[j]);
		num[i] = (x[i]-*aveX)*(y[j]-*aveY);
		Xden[i] = ((x[i]-*aveX)*(x[i]-*aveX));
		Yden[i] = ((y[j]-*aveY)*(y[j]-*aveY));
	}

	// __syncthreads();
	g.sync();

	if(i==nx){
		double numerator = 0, d1 = 0, d2 = 0;
		for(int j = 0; j < nx; j++){
			numerator += num[j];
			d1 += Xden[j];
			d2 += Yden[j];
		}
		*r = numerator/((__dsqrt_rn(d1))*(__dsqrt_rn(d2)));
	}
}

// void calcAverage(int numPoints, int size, double* input, double* output, double* delta);

double* calcPearson(int nx, double* x, int* xDates, int ny, double* y, int* yDates){
	double* correlation = new double;
	double* d_r, *d_aveX, *d_aveY;

	cudaMalloc((void**)&d_r, sizeof(double));
	cudaMalloc((void**)&d_aveX, sizeof(double));
	cudaMalloc((void**)&d_aveY, sizeof(double));

	double* d_numerator, *d_Xden, *d_Yden;

	

	if(nx > ny){
		gpuErrchk(cudaMalloc((void**)&d_numerator, nx*sizeof(double)));
		gpuErrchk(cudaMalloc((void**)&d_Xden, nx*sizeof(double)));
		gpuErrchk(cudaMalloc((void**)&d_Yden, nx*sizeof(double)));
		pearson<<<(nx)/1024 + 1, 1024>>>(nx, x, xDates, ny, y, yDates, d_r, d_numerator, d_Xden, d_Yden, d_aveX, d_aveY);
	}
	else{
		gpuErrchk(cudaMalloc((void**)&d_numerator, ny*sizeof(double)));
		gpuErrchk(cudaMalloc((void**)&d_Xden, ny*sizeof(double)));
		gpuErrchk(cudaMalloc((void**)&d_Yden, ny*sizeof(double)));
		pearson<<<(ny)/1024 + 1, 1024>>>(ny, y, yDates, nx, x, xDates, d_r, d_numerator, d_Xden, d_Yden, d_aveX, d_aveY);
	}

	cudaMemcpy(correlation, d_r, sizeof(double), cudaMemcpyDeviceToHost);

	cudaFree(d_numerator);
	cudaFree(d_Xden);
	cudaFree(d_Yden);
	cudaFree(d_r);
	cudaFree(d_aveX);
	cudaFree(d_aveY);

	return correlation;
}

int parseDate(char* date){
	char* year, *month, *day;
	bool first = false;
	year = date;
	for(int i = 0; date[i] != '\0'; i++){
		if(date[i] == '-'){
			date[i] = '\0';
			if(!first){
				first = true;
				month = &date[i+1];
			}
			else{
				day = &date[i+1];
			}
		}
	}
	// cout<<year<<endl;
	// cout<<month<<endl;
	// cout<<day<<endl;
	return stoi(year)*365 + stoi(month)*30 + stoi(day);
}

__global__ void optionPrice(double* stockPrices, int numDays, double* strikes, double* maturity, bool* call, double* optionPrices, int numOptions){
	int i = blockIdx.x*blockDim.x+threadIdx.x;
	double R = 1.0202;
	__shared__ double deviation;
	if(threadIdx.x == 0){
		double average = 0;
		for(int j = 0; j <= numDays; j++){
			average += stockPrices[j];
		}
		average /= numDays;
		// printf("numdays: %d average: %f\n", numDays, average);
		deviation = 0;
		for(int j = 0; j <= numDays; j++){
			double in = (stockPrices[j] - average) * (stockPrices[j] - average);
			deviation += in;
			// printf("%f\n", in);
		}
		deviation /= numDays-1;
		// deviation = 
		// volatility = __dsqrt_rn(deviation);
		deviation = __dsqrt_rn(deviation);
		deviation *= __dsqrt_rn(numDays);
		deviation /= average;
		// printf("%f\n", deviation);
	}

	__syncthreads();

	if (i < numOptions){
		if(call[i]){
			double priceUp = stockPrices[numDays-1] + stockPrices[numDays-1] * deviation * maturity[i];
			double priceDown = stockPrices[numDays-1] - stockPrices[numDays-1] * deviation * maturity[i];
			if(priceDown < 0) priceDown = 0;
			// printf("%d %f %f %c\n", i, strikes[i], maturity[i], call[i]);
			// printf("+%f -%f\n", priceUp, priceDown);
			double maxUp = priceUp - strikes[i];
			if(maxUp < 0) maxUp = 0;
			double maxDown = priceDown - strikes[i];
			if(maxDown < 0) maxDown = 0;
			double valPrice = (maxUp-maxDown)/(priceUp-priceDown);
			optionPrices[i] = (stockPrices[numDays-1] * valPrice) + ((maxUp - (priceUp * valPrice))/exp(-R*maturity[i]));
			// printf("%d %f %f %f %f\n", i, stockPrices[numDays-1], maturity[i], strikes[i], optionPrices[i]);
		}
	}

	// __syncthreads();
	
}
// double* stockPrices, int numDays, double* strikes, double* maturity, bool* call, double* optionPrices, int numOptions
__global__ void launch(double** prices, int* sizes, int n, int* status, double** optionPrices, double** strikes, double** exp, bool** calls, int* numOptions){
	int i = blockIdx.x*blockDim.x+threadIdx.x;
	// printf("%d %d\n", i, n);
	if(i < n){
		if(sizes[i] > 10){
			// printf("%d < %d\n", i, n);
			// printf("%d %d\n", i, prices[i][0]);
			unsigned int blocks = 512/sizes[i]+1, threads = 512;
			// const dim3 coopBlocks = {blocks, 1, 1};
			// const dim3 coopThreads = {threads, 1, 1};
			double* ten = new double[sizes[i]], *five = new double[sizes[i]];
			double* d1, *d5, *d10, *d2_5, *d2_10, *std;
			
			d1 = new double[sizes[i]];
			d5 = new double[sizes[i]];
			d10 = new double[sizes[i]];
			d2_5 = new double[sizes[i]];
			d2_10 = new double[sizes[i]];
			// do{
			std = new double[sizes[i]];	//for some reason this sometimes sets to the null pointer, might run out of memory? no fucking clue why
				// if(std == 0)
					// delete[] std;
			// }while(std == 0);
			// printf("%p %p %p %p %p %p\n", d1, d5, d10, d2_5, d2_10, std);
			// normstdev = new double[sizes[i]];
			double* ave = new double;
			// for(int j = 0; j < sizes[i]; j++){
			// 	printf("%d %f", i, prices[i][j]);
			// __syncthreads();
			cudaDeviceSynchronize();
			movingAvg<<<blocks, threads>>>(sizes[i], 10, prices[i], five);
			cudaDeviceSynchronize();
			movingAvg<<<blocks, threads>>>(sizes[i], 20, prices[i], ten);
			cudaDeviceSynchronize();
			deltas<<<blocks, threads>>>(sizes[i], prices[i], d1);
			cudaDeviceSynchronize();
			deltas<<<blocks, threads>>>(sizes[i], five, d5);
			cudaDeviceSynchronize();
			deltas<<<blocks, threads>>>(sizes[i], ten, d10);
			cudaDeviceSynchronize();
			deltas<<<blocks, threads>>>(sizes[i], d5, d2_5);
			cudaDeviceSynchronize();
			deltas<<<blocks, threads>>>(sizes[i], d10, d2_10);
			cudaDeviceSynchronize();
			stdDev<<<blocks, threads>>>(sizes[i], 20, prices[i], std);
			cudaDeviceSynchronize();
			if(sizes[i] >= 253)
				optionPrice<<<numOptions[i]/512+1, 512>>>(&(prices[i][sizes[i]-253]), 252, strikes[i], exp[i], calls[i], optionPrices[i], numOptions[i]);
			else
				optionPrice<<<numOptions[i]/512+1, 512>>>(prices[i], sizes[i], strikes[i], exp[i], calls[i], optionPrices[i], numOptions[i]);
			cudaDeviceSynchronize();

			// void* paramlist[3] = {(void*)&sizes[i], (void*)&ave, (void*)&stdev};
			// cudaLaunchCooperativeKernel((void*)normalize, coopBlocks, coopThreads, paramlist);
			normalize<<<blocks, threads>>>(&sizes[i], ave, std);
			status[i] = 0;
			// __syncthreads();
			int index = sizes[i]-1;
			// if(i==821)
			// for(int index = 0; index < sizes[i]; index++)
			// 	printf("%d %d %f %f %f %f %f %f %f\n", i, index, prices[i][index], d1[index], five[index], d5[index], d2_5[index], ten[index], d10[index], d2_10[index], std[index]);
			if((d10[index] < 0.02 || d10[index] > -0.02) && d2_5[index] > 0 && d5[index] > 0 && std[index] < 2){
				status[i] = 1;
			}
			else if( ((d2_5[index] < 0 && (zero(d5[index]) || d5[index] < -0.002)) ) || (d2_10[index] < 0 && (zero(d10[index] || d10[index] < -.002))) ) {
				status[i] = 2;
			}
			else if(prices[i][index-1] < five[index-1] && prices[i][index] > five[index] && std[index] > 1){
				status[i] = 2;
			}
			// __syncthreads();
			cudaDeviceSynchronize();
			delete[] ten;
			delete[] five;
			delete[] d1;
			delete[] d5;
			delete[] d10;
			delete[] d2_5;
			delete[] d2_10;
			delete[] std;
			delete ave;
		}
	}
}

int main(int argc, char** argv) {
	gpuErrchk(cudaSetDevice(1));
	cudaDeviceSynchronize();

	// CSVReader file = CSVReader(argv[1]);
	// CSVReader option = CSVReader(argv[1]);
	// cout<<argv[1]<<endl;
	// int on = 0;
	// // gpuErrchk(cuDevicePrimaryCtxGetState(1, nullptr, &on));
	// if(on){
	// 	cout<<"Context initialized"<<endl;
	// }
	vector<char*>* symbols = new vector<char*>();
	listDir("./proc", symbols);
	vector<AVData*> dataList = vector<AVData*>();
	vector<OptionData*> optionList = vector<OptionData*>();

	for(int i = 2; i < symbols->size(); i++){
		char* dirName = new char[100];
		strcpy(dirName, "./proc/");
		// cout<<(*symbols)[i]<<endl;
		AVData* temp = new AVData(strcat(dirName, (*symbols)[i]));
		dataList.push_back(temp);

		strcpy(dirName, "./options/");
		OptionData* temp2 = new OptionData(strcat(dirName, (*symbols)[i]));
		optionList.push_back(temp2);
	}

	double** d_prices, **prices = new double*[dataList.size()];
	int* d_pSizes, *pSizes = new int[dataList.size()];

	
	// cout<<wrapperSize<<' '<<cudaMem<<' '<<cudaMemTotal<<endl;
	// cudaDeviceSynchronize();

	gpuErrchk(cudaMalloc((void**)&d_pSizes, dataList.size()*sizeof(int)));
	// cudaDeviceSynchronize();
	gpuErrchk(cudaMalloc((void**)&d_prices, dataList.size()*sizeof(double*)));
	cudaDeviceSynchronize();
	size_t totalSize = 0;
	// totalSize += dataList.size()*sizeof(int) + dataList.size()*sizeof(double*);
	for(int i = 0; i < dataList.size(); i++){
		
		dataList[i]->tokenize();
		// printf("%d %d %s\n", i, dataList[i]->price()->size(), dataList[i]->fileName());
		size_t size = dataList[i]->price()->size()*sizeof(double);
		gpuErrchk(cudaMalloc((void**)&(prices[i]), size));
		cudaDeviceSynchronize();
		gpuErrchk(cudaMemcpy(prices[i], dataList[i]->price()->data(), size, cudaMemcpyHostToDevice));
		cudaDeviceSynchronize();
		pSizes[i] = dataList[i]->price()->size();
		totalSize += dataList[i]->price()->size()*sizeof(double)*9 + sizeof(double);
	}
	
	cudaDeviceSynchronize();
	gpuErrchk(cudaMemcpy(d_pSizes, pSizes, dataList.size()*sizeof(int), cudaMemcpyHostToDevice));
	// cudaDeviceSynchronize();
	gpuErrchk(cudaMemcpy(d_prices, prices, dataList.size()*sizeof(double), cudaMemcpyHostToDevice));
	cudaDeviceSynchronize();

	int * d_status, *status = new int[dataList.size()];
	cudaMalloc((void**)&d_status, dataList.size()*sizeof(int));

	cudaDeviceSynchronize();
	size_t cudaMem, cudaMemTotal;//, wrapperSize = dataList.size()*sizeof(int);
	// totalSize *= 2;
	// gpuErrchk(cudaDeviceSynchronize());
	gpuErrchk(cudaMemGetInfo(&cudaMem, &cudaMemTotal));
	cout<<"Allocating "<<totalSize<<" bytes on device\n";

	gpuErrchk(cudaDeviceSetLimit(cudaLimitMallocHeapSize, totalSize));

	// double* stockPrices, int numDays, double* strikes, double* maturity, bool* call, double* optionPrices, int numOptions

	double **d_optionPrices = 0, **d_strikes = 0, ** optionPrices= new double*[optionList.size()], **strikes = new double*[optionList.size()];
	int *numOptions = 0, *d_numOptions = 0;
	double **d_exp = 0, **exp = new double*[optionList.size()];
	bool** d_call = 0, **call = new bool*[optionList.size()];

	numOptions = new int[optionList.size()];
	cudaMalloc((void**)&d_optionPrices, optionList.size()*sizeof(double*));
	cudaMalloc((void**)&d_exp, optionList.size()*sizeof(double*));
	cudaMalloc((void**)&d_call, optionList.size()*sizeof(bool*));
	cudaMalloc((void**)&d_strikes, optionList.size()*sizeof(double*));
	cudaMalloc((void**)&d_numOptions, optionList.size()*sizeof(int));
	// cout<<"1\n";
	for(int i = 0; i < optionList.size(); i++){
		optionList[i]->tokenize();
		cudaMalloc((void**)&(optionPrices[i]), optionList[i]->call.size()*sizeof(double));
		cudaMalloc((void**)&(exp[i]), optionList[i]->exp.size()*sizeof(double));
		cudaMalloc((void**)&(call[i]), optionList[i]->call.size()*sizeof(bool));
		cudaMalloc((void**)&(strikes[i]), optionList[i]->strike.size()*sizeof(double));

		cudaMemcpy(exp[i], optionList[i]->exp.data(), optionList[i]->exp.size()*sizeof(double), cudaMemcpyHostToDevice);
		cudaMemcpy(call[i], optionList[i]->call.data(), optionList[i]->call.size()*sizeof(bool), cudaMemcpyHostToDevice);
		cudaMemcpy(strikes[i], optionList[i]->strike.data(), optionList[i]->strike.size()*sizeof(double), cudaMemcpyHostToDevice);
		numOptions[i] = optionList[i]->call.size();
	}

	// cout<<"2\n";
	// cudaMalloc
	gpuErrchk( cudaMemcpy(d_exp, exp, optionList.size()*sizeof(double*), cudaMemcpyHostToDevice));
	gpuErrchk( cudaMemcpy(d_optionPrices, optionPrices, optionList.size()*sizeof(double*), cudaMemcpyHostToDevice));
	cudaMemcpy(d_call, call, optionList.size()*sizeof(bool*), cudaMemcpyHostToDevice);
	cudaMemcpy(d_strikes, strikes, optionList.size()*sizeof(double*), cudaMemcpyHostToDevice);
	cudaMemcpy(d_numOptions, numOptions, optionList.size()*sizeof(int), cudaMemcpyHostToDevice);

	// printf("OP: %p OP[0]: %p\n", optionPrices, optionPrices[0]);
	// printf("d_OP: %p d_OP[0]: %p\n", d_optionPrices, d_optionPrices[0]);
	// gpuErrchk(cudaMalloc((void**)))

	// double** prices, int* sizes, int n, int* status, double** optionPrices, double** strikes, int** exp, bool** calls, int* numOptions

	cudaDeviceSynchronize();
	launch<<<dataList.size()/512+1, 512>>>(d_prices, d_pSizes, dataList.size(), d_status, d_optionPrices, d_strikes, d_exp, d_call, d_numOptions);
	cudaDeviceSynchronize();

	// double **temp = new double*[optionList.size()];

	for(int i = 0; i < optionList.size(); i++){
		double *temp = new double[optionList[i]->call.size()];
		// printf("%p\n", d_optionPrices[i]);
		cudaMemcpy(temp, optionPrices[i], optionList[i]->call.size()*sizeof(double), cudaMemcpyDeviceToHost);
		cudaDeviceSynchronize();
		cudaFree(optionPrices[i]);

		optionPrices[i] = temp;
		optionList[i]->comparePrices(optionPrices[i]);

		cudaFree(exp[i]);
		cudaFree(strikes[i]);
		cudaFree(call[i]);
	}

	cudaFree(d_exp);
	cudaFree(d_strikes);
	cudaFree(d_call);
	cudaFree(d_numOptions);
	cudaFree(d_optionPrices);
	cudaDeviceSynchronize();

	cudaMemcpy(status, d_status, dataList.size()*sizeof(int), cudaMemcpyDeviceToHost);
	cudaDeviceSynchronize();
	cout<<"-------------------Long-------------------\n";
	for(int i = 0; i < dataList.size(); i++){
		// cout<<status[i]<<endl;
		if(status[i] == 1)
			cout<<dataList[i]->fileName()<<endl;
	}
	cout<<"-------------------Short-------------------\n";
	for(int i = 0; i < dataList.size(); i++){
		if(status[i] == 2)
			cout<<dataList[i]->fileName()<<endl;
		// cout<<i<<endl;
		cudaFree(prices[i]);
	}

	cudaFree(d_pSizes);
	cudaFree(d_prices);

	// cudaFree()
	delete[] optionPrices;
	delete[] exp;
	delete[] strikes;
	delete[] call;
	delete[] prices;
	delete[] pSizes;
	delete[] status;

	// if (file.isOpen()){
	// 	// char* line = new char[256];
	// 	// file.getline(line, 256);
	// 	// cout<<line<<endl;
	// 	// file.getline();
	// 	vector<int> timestamp;
	// 	vector<double> open;
	// 	vector<double> high;
	// 	vector<double> low;
	// 	vector<double> close;
	// 	vector<double> volume;
	// 	double *five, *ten, *twenty, *d1, *d5, *d10, *d20, *d_averages, *d_data, *d_aved, *d_stdev, *stdev, *dstdev, *ave;
	// 	int* d_n;
	// 	unsigned int blocks, threads;
		
	// 	int numPoints = 0;

	// 	// file.getline();
	// 	while(vector<char*>* tokenized = file.getline()){
	// 		if(!file.eof()){
	// 			numPoints++;
	// 			// cout<<(*tokenized)[0]<<endl;
	// 			// for(int j = 0; (*tokenized)[0][j] != '\0'; j++){
	// 			// 	if((*tokenized)[0][j] == '-'){
	// 			// 		(*tokenized)[0][j] = '\0';
						
	// 			// 	}
	// 			// }

	// 			// timestamp.push_back(parseDate((*tokenized)[0]));	//possible memory leak/delete error here, shouldn't be a problem with others because they copy data during double conversion
	// 			open.push_back(stod((*tokenized)[1]));
	// 			high.push_back(stod((*tokenized)[2]));
	// 			low.push_back(stod((*tokenized)[3]));
	// 			close.push_back(stod((*tokenized)[4]));
	// 			volume.push_back(stod((*tokenized)[5]));
				
	// 		}
	// 		else break;
	// 	}
	// 	gpuErrchk(cudaMalloc((void**)&d_data, numPoints*sizeof(double)));
	// 	gpuErrchk(cudaMalloc((void**)&d_averages, numPoints*sizeof(double)));
	// 	cudaMalloc((void**)&d_aved,(numPoints)*sizeof(double));
	// 	cudaMalloc((void**)&d_stdev, numPoints*sizeof(double));
	// 	cudaMalloc((void**)&ave, sizeof(double));

	// 	// averages = (double*) calloc(numPoints, sizeof(double));
	// 	five = new double[numPoints];
	// 	ten = new double[numPoints];
	// 	twenty = new double[numPoints];
	// 	d1 = new double[numPoints];
	// 	d5 = new double[numPoints];
	// 	d10 = new double[numPoints];
	// 	// d20 = new double[numPoints];
	// 	stdev = new double[numPoints];
	// 	dstdev = new double[numPoints];
	// 	blocks = numPoints/1024+1;
	// 	threads = 1024;
	// 	const dim3 coopBlocks = {blocks, 1, 1};
	// 	const dim3 coopThreads = {threads, 1, 1};
	// 	double* d_st2;
	// 	// double* data = close.data();
	// 	int range = 5;
	// 	cudaMalloc((void**)&d_n, sizeof(int));
	// 	cudaMemcpy(d_n, &numPoints, sizeof(int), cudaMemcpyHostToDevice);

	// 	double* stdstd = new double[numPoints];

	// 	cudaMalloc((void**)&d_st2, numPoints*sizeof(double));

	// 	gpuErrchk(cudaMemcpy(d_data, close.data(), numPoints*sizeof(double), cudaMemcpyHostToDevice));
	// 	// gpuErrchk(cudaMemcpy(d_averages, averages, numPoints*sizeof(double), cudaMemcpyHostToDevice));
	// 	cudaDeviceSynchronize();

	// 	stdDev<<<blocks, threads>>>(numPoints, range, d_data, d_stdev);

	// 	cudaDeviceSynchronize();

	// 	// double* temp = new double[numPoints];
		
	// 	// cudaMemcpy(temp, d_stdev, numPoints*sizeof(double), cudaMemcpyDeviceToHost);

	// 	// cudaDeviceSynchronize();

	// 	// cudaMemcpy(d_stdev, temp, numPoints*sizeof(double), cudaMemcpyHostToDevice);

	// 	// cudaDeviceSynchronize();
	// 	// double ave = 0;
	// 	// for(int j = 0; j < numPoints; j++){
	// 	// 	// cout<<j<<" "<<temp[j]<<endl;
	// 	// 	ave += d_stde
	// 	// }

	// 	// normalize<<<(numPoints/1024)+1, 1024>>>(numPoints, ave, d_stdev);
	// 	void* paramlist[3] = {(void*)&d_n, (void*)&ave, (void*)&d_stdev};
	// 	gpuErrchk(cudaLaunchCooperativeKernel((void*)normalize, coopBlocks, coopThreads, paramlist));

	// 	cudaDeviceSynchronize();

	// 	// cudaMemcpy(temp, d_stdev, numPoints*sizeof(double), cudaMemcpyDeviceToHost);

	// 	// for(int j = 0; j < numPoints; j++){
	// 	// 	cout<<j<<" "<<temp[j]<<endl;
	// 	// }

	// 	double* d_dstdAve, *dstdAve = new double[numPoints];

	// 	cudaMalloc((void**)&d_dstdAve, numPoints*sizeof(double));

	// 	// stdDev<<<blocks, threads>>>(numPoints, range, d_stdev, d_st2);
	// 	deltas<<<blocks, threads>>>(numPoints, d_stdev, d_aved);
	// 	movingAvg<<<blocks, threads>>>(numPoints, range, d_aved, d_dstdAve);


	// 	cudaMemcpy(stdev, d_stdev, numPoints*sizeof(double), cudaMemcpyDeviceToHost);
	// 	cudaMemcpy(dstdev, d_aved, numPoints*sizeof(double), cudaMemcpyDeviceToHost);
	// 	cudaMemcpy(dstdAve, d_dstdAve, numPoints*sizeof(double), cudaMemcpyDeviceToHost);

	// 	cudaDeviceSynchronize();

	// 	deltas<<<blocks, threads>>>(numPoints, d_data, d_aved);

	// 	// movingAvg<<<blocks, threads>>>(numPoints, range, )

	// 	cudaDeviceSynchronize();

	// 	cudaMemcpy(d1, d_aved, numPoints*sizeof(double), cudaMemcpyDeviceToHost);

	// 	cudaDeviceSynchronize();

	// 	movingAvg<<<blocks, threads>>>(numPoints, range, d_data, d_averages);
	// 	deltas<<<blocks, threads>>>(numPoints, d_averages, d_aved);

	// 	gpuErrchk(cudaDeviceSynchronize());

	// 	// double* dAve = new double[numPoints];
	// 	cudaMemcpy(d5, d_aved, numPoints*sizeof(double), cudaMemcpyDeviceToHost);
	// 	cudaMemcpy(five, d_averages, numPoints*sizeof(double), cudaMemcpyDeviceToHost);
	// 	cudaDeviceSynchronize();

	// 	deltas<<<blocks, threads>>>(numPoints, d_aved, d_averages);
	// 	cudaDeviceSynchronize();

	// 	double* d2_5 = new double[numPoints];
	// 	cudaMemcpy(d2_5, d_averages, numPoints*sizeof(double), cudaMemcpyDeviceToHost);
	// 	cudaDeviceSynchronize();

	// 	movingAvg<<<blocks, threads>>>(numPoints, range*2, d_data, d_averages);
	// 	deltas<<<blocks, threads>>>(numPoints, d_averages, d_aved);
	// 	cudaMemcpy(ten, d_averages, numPoints*sizeof(double), cudaMemcpyDeviceToHost);
	// 	cudaMemcpy(d10, d_aved, numPoints*sizeof(double), cudaMemcpyDeviceToHost);

	// 	cudaDeviceSynchronize();

	// 	deltas<<<blocks, threads>>>(numPoints, d_aved, d_averages);
	// 	cudaDeviceSynchronize();

	// 	double* d2_10 = new double[numPoints];
	// 	cudaMemcpy(d2_10, d_averages, numPoints*sizeof(double), cudaMemcpyDeviceToHost);
	// 	cudaDeviceSynchronize();

	// 	cudaFree(d_data);
	// 	cudaFree(d_averages);
	// 	cudaFree(d_aved);
	// 	cudaFree(d_stdev);
	// 	// cudaFree(d_xD);
	// 	// cudaFree(d_yD);
	// 	// cudaFree(d_gdpd);
		
		

	// 	ofstream output;

	// 	char dir[] = "/home/aidan/stocks/output.csv";
	// 	// strcat(dir, argv[2]);
	// 	// strcat(dir, ".csv");
	// 	// cout<<dir<<endl;
	// 	output.open(dir);
	// 	char delim = ',';
	// 	output<<"n,shares,close,average,balance,stdDev,ten,five2,ten2\n";

	// 	double balance = 1000;
	// 	int numShares = 0;
	// 	double buyPrice;
	// 	int simpleShares = balance/close[range*2+1];
	// 	// cout<<simpleShares<<" at "<<close[range*2+1]<<endl;
	// 	for(int i = range*2+1; i < numPoints; i++){
	// 		// if(close[i] > five[i] && numShares > 0 && dstdev[i] < 0 && dstdev[i-1] > 0){
	// 		// 	cout<<i<<" Significant Price Increase Sell ";
	// 		// 	balance += numShares*close[i];
	// 		// 	numShares = 0;
	// 		// }
	// 		// if(five[i] < ten[i] && numShares > 0){
	// 		// 	cout<<i<<" Significant +/- Crossover Sell ";
	// 		// 	balance += numShares*close[i];
	// 		// 	numShares = 0;
	// 		// }
	// 		// else if(five[i] > ten[i] && numShares == 0){
	// 		// 	cout<<i<<" -/+ Crossover Buy ";
	// 		// 	while(balance > close[i]){
	// 		// 		buyPrice = close[i];
	// 		// 		balance -= close[i];
	// 		// 		numShares ++;
	// 		// 	}
	// 		// }
	// 		// // else if(numShares == 0 && ((dstdev[i] < 0 && dstdev[i-1] > 0 && close[i] < five[i]) || (dstdev[i] > 0 && dstdev[i-1] < 0 && close[i] > five[i])) && d5[i] > -0.1){
	// 		// // 	cout<<i<<" Dip Buy ";
	// 		// // 	while(balance > close[i]){
	// 		// // 		buyPrice = close[i];
	// 		// // 		balance -= close[i];
	// 		// // 		numShares ++;
	// 		// // 	}
	// 		// // }
	// 		// if(numShares > 0 && close[i] <= .85*buyPrice){
	// 		// 	cout<<i<<" Cut and Run ";
	// 		// 	balance += numShares*close[i];
	// 		// 	numShares = 0;
	// 		// }
	// 		// if(close[i] > buyPrice && numShares > 0 && close[i] < five[i] && dAve[i] > 0){
	// 		// 	cout<<i<<" Make Hay While The Sun Shines ";
	// 		// 	balance += numShares*close[i];
	// 		// 	numShares = 0;
	// 		// }
	// 		// if(close[i] > five[i] && numShares == 0 && dstdev[i] > 0 && dstdev[i-1] < 0 && d5[i] > 0){
	// 		// 	cout<<i<<" Tryna Make Up Some Panic Money ";
	// 		// 	while(balance > close[i]){
	// 		// 		buyPrice = close[i];
	// 		// 		balance -= close[i];
	// 		// 		numShares ++;
	// 		// 	}
	// 		// }

	// 		if(numShares == 0 && (d10[i] < 0.02 || d10[i] > -0.02) && d2_5[i] > 0 && d5[i] > 0 && stdev[i] < 2){
	// 			// cout<<"buying ";
	// 			while(balance > close[i]){
	// 				buyPrice = close[i];
	// 				balance -= close[i];
	// 				numShares ++;
	// 			}
	// 		}
	// 		else if(numShares > 0 && ((d2_5[i] < 0 && (zero(d5[i]) || d5[i] < -0.002)) ) || (d2_10[i] < 0 && (zero(d10[i] || d10[i] < -.002))) ) {
	// 			// cout<<"selling ";
	// 			balance += numShares*close[i];
	// 			numShares = 0;
	// 		}
	// 		else if(numShares > 0 && (stdev[i] > 1 || (close[i-1] < five[i-1] && close[i] > five[i] && stdev[i] > 1))) {
	// 			// cout<<"too large of an increase, selling ";
	// 			balance += numShares*close[i];
	// 			numShares = 0;
	// 		}
	// 		// cout<<i<<' '<<d1[i]<<' '<<d5[i]<<' '<<d2_5[i]<<' '<<d10[i]<<' '<<d2_10[i]<<endl;
	// 		output<<i<<delim<<numShares<<delim<<close[i]<<delim<<five[i]<<delim<<(numShares*close[i] + balance)<<delim<<stdev[i]<<delim<<ten[i]<<delim<<d2_5[i]<<delim<<d2_10[i]<<endl;
	// 	}
	// 	// cout<<simpleShares<<" at "<<close.back()<<endl;
	// 	cout<<(numShares*close.back()+balance)<<" compared to "<<(simpleShares*close.back()+(1000-simpleShares*close[range+1]))<<endl;

	// 	output.close();
	// 	// delete correlation;
	// 	delete[] five;
	// 	delete[] ten;
	// 	delete[] twenty;
	// 	delete[] d5;
	// 	delete[] d10;
	// 	// delete[] d20;
	// 	delete[] stdev;
	
	// }
	return 0;
}

__device__ bool zero(double in){
	double thresh = .002;
	if(in < thresh && in > -thresh){
		// cout<<in<<"~=0\n";
		return true;
	}
	return false;
}

CSVReader::CSVReader(char* fn){
	setFile(fn);
}

void CSVReader::setFile(char* fn){
	file.open(fn);
	filename = fn;//memory leak, causes segfault if initialized from argv. Need to implement copy iterator for strings.
}

vector<char*>* CSVReader::getline(){
	vector<char*>* tokenized;
	if(!this->eof()){
		tokenized = new vector<char*>;//mem leak?
		if(!file.eof()){
			char* line = new char[256];
			// cout<<*line<<endl;

			file.getline(line, 256);
			// cout<<line[0]<<line[1]<<line[2]<<line[3]<<line[4]<<line[5]<<endl;
			tokenized->push_back(&line[0]);
			for(int i = 0; line[i] != '\0'; i++){
				if(line[i]==','){
					line[i] = '\0';
					tokenized->push_back(&line[i+1]);
				}
			}	
		}
	}
	return tokenized;	
}

bool CSVReader::eof(){
	// cout<<"checking eof\n";
	return file.eof();
}

bool CSVReader::isOpen(){
	return file.is_open();
}

CSVReader::~CSVReader(){//eventually add delete[] filename;
	file.close();
}

CSVReader::CSVReader(const CSVReader& copy){
	filename = copy.filename;
	file.open(filename);
}

const char* CSVReader::fileName(){
	return filename;
}

void AVData::tokenize(){
	if(isOpen()){
		while(vector<char*>* tokenized = this->getline()){
			if(!this->eof()){
				// cout<<filename<<endl;
				// cout<<(*tokenized)[1]<<endl;
				open.push_back(stod((*tokenized)[1]));
				high.push_back(stod((*tokenized)[2]));
				low.push_back(stod((*tokenized)[3]));
				close.push_back(stod((*tokenized)[4]));
				volume.push_back(stod((*tokenized)[5]));
			}
			else break;
		}
	}
}

AVData::AVData(char* fn) : CSVReader(fn){}

void listDir(char* dirPath, vector<char*>* v){
	DIR* dirp = opendir(dirPath);
	struct dirent * dp;
	while((dp = readdir(dirp)) != NULL){
		char* temp = new char[strlen(dp->d_name)+1];
		memcpy(temp, dp->d_name, strlen(dp->d_name)+1);
		v->push_back(temp);
		// cout<<temp<<endl;
	}
	closedir(dirp);
}

const vector<double>* AVData::price(){
	return &close;
}

OptionData::OptionData(char* fn) : CSVReader(fn){}

void OptionData::tokenize(){
	if(isOpen()){
		time_t curTime = time(0);
		// cout<<curTime<<endl;
		while(vector<char*>* tokenized = this->getline()){
			if(!this->eof()){
				// cout<<"Reading Line"<<endl;

				call.push_back((strcmp((*tokenized)[0], "C") == 0));
				exp.push_back((stod((*tokenized)[1])+16*3600 - curTime)/(365*24*60*60));
				strike.push_back(stod((*tokenized)[2]));
				bid.push_back(stod((*tokenized)[3]));
				ask.push_back(stod((*tokenized)[4]));
				impVol.push_back(stod((*tokenized)[5]));

			}
			else break;
		}
	}
}

bool* OptionData::comparePrices(double* optionPrices){
	bool* temp = new bool[ask.size()];
	for(int i = 0; i < ask.size(); i++){
		temp[i] = optionPrices[i] < ask[i];
		if(call[i])
			printf("%f %f %f %f\n", exp[i], strike[i], optionPrices[i], ask[i]);
	}
	return temp;
}