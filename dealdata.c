#ifndef _LARGEFILE64_SOURCE
#define _LARGEFILE64_SOURCE
#endif

#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <signal.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>
#include <sys/ipc.h>
#include <sys/sem.h>
#include <sys/wait.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/file.h>
#include <time.h>
#include <dirent.h>

char *g_str, g_rootdir[1024], header[16 * 1024 * 1024], result[16 * 1024 * 1024];

#if 0
static int check_resultdir(char *dirname, char *sub_dirname)
{
	char buf[1024];
	struct stat stbuf;

	snprintf(buf, sizeof(buf) - 1, "%s/%s/%s/__edp_socket_view_summary.csv", g_rootdir, dirname, sub_dirname);
	if(stat(buf, &stbuf) == 0) {
		return 0;
	}

	snprintf(buf, sizeof(buf) - 1, "cp -rf %s/chart_format.txt %s/%s/%s/.", g_rootdir, g_rootdir, dirname, sub_dirname);
	system(buf);
	//snprintf(buf, sizeof(buf) - 1, "cp -rf %s/metric.xml %s/%s/%s/.", g_rootdir, g_rootdir, dirname, sub_dirname);
	//system(buf);
	snprintf(buf, sizeof(buf) - 1, "cp -rf %s/edp.rb %s/%s/%s/.", g_rootdir, g_rootdir, dirname, sub_dirname);
	system(buf);
	snprintf(buf, sizeof(buf) - 1, "cp -rf %s/proc.sh %s/%s/%s/.", g_rootdir, g_rootdir, dirname, sub_dirname);
	system(buf);

	snprintf(buf, sizeof(buf) - 1, "%s/%s/%s/", g_rootdir, dirname, sub_dirname);
	chdir(buf);
	
	system("./proc.sh &");
}
#else
static int check_subdir(char *dirname, char *sub_dirname, float *total, float *latency, float *tps)
{
	int fd = -1, ret = -1;
	struct stat stbuf;
	char *p, *q, *buf = NULL, filename[1024];

	snprintf(filename, sizeof(filename) - 1, "%s/%s", dirname, sub_dirname);
	if(stat(filename, &stbuf) < 0) {
		printf("stat %s failed.\n", filename);
		goto end;
	}

	fd = open(filename, O_RDONLY);
	if(fd < 0) {
		printf("open %s failed.\n", filename);
		goto end;
	}
	
	buf = (char *)malloc(stbuf.st_size + 1);
	if(buf == NULL) {
		printf("malloc failed.\n");
		goto end;
	}

	buf[stbuf.st_size] = 0;
	if(read(fd, buf, stbuf.st_size) != stbuf.st_size) {
		printf("read failed.\n");
		goto end;
	}

	p = strstr(buf, "queries:");
	if(p == NULL) {
		printf("%s format is wrong.\n", filename);
		goto end;
	}

	p += 17;
	while(*p == ' ')
		p++;
	
	q = strchr(p, '(');
	if(q == NULL) {
		printf("%s format is wrong.\n", filename);
		goto end;
	}

	*total += atof(q + 1);

	p = strstr(buf, "transactions:");
	if(p == NULL) {
		printf("%s format is wrong.\n", filename);
		goto end;
	}

	p += 17;
	while(*p == ' ')
		p++;
	
	q = strchr(p, '(');
	if(q == NULL) {
		printf("%s format is wrong.\n", filename);
		goto end;
	}

	*tps += atof(q + 1);

	p = strstr(buf, "avg:");
	if(p == NULL) {
		printf("%s format is wrong.\n", filename);
		goto end;
	}

	p += 17;
	while(*p == ' ')
		p++;
	
	*latency += atof(p);

	close(fd);
	ret = 0;
end:;
	if(buf)
		free(buf);
	if(fd >= 0)
		close(fd);
	return ret;
}

int check_resultdir(char *dirname, char *sub_dirname)
{
	DIR *dp;
	struct stat stbuf;
	struct dirent *de;
	float total = 0, latency = 0, tps  = 0;
	int fd, is_first = 0, cnt = 0, ret = 0;
	char *p, *q, *buf = NULL, temp[128], full_dirname[1024], filename[1024];

	snprintf(full_dirname, sizeof(full_dirname) - 1, "%s/%s/result", dirname, sub_dirname);

	if((dp = opendir(full_dirname)) == NULL) {
		printf("opendir %s failed\n", full_dirname);
		return -1;
	}

	while((de = readdir(dp)) != NULL) {
		if( (strcmp(de->d_name, ".") == 0) || (strcmp(de->d_name, "..") == 0) )
			continue;

		if(check_subdir(full_dirname, de->d_name, &total, &latency, &tps) < 0) {
			ret = -1;
			break;
		}
		cnt += 1;
	}
	closedir(dp);

	strncpy(filename, sub_dirname, sizeof(filename));
	p = strchr(filename, '_');
	if(p == NULL) {
		printf("%s format is wrong.\n", filename);
		goto end;
	}
	//*p = 0;
	strncat(result, filename, sizeof(result) - 1);
	strncat(result, ",", sizeof(result) - 1);

	snprintf(temp, sizeof(temp) - 1, "%d,", atoi(filename + 2));
	strncat(result, temp, sizeof(result) - 1);

	q = strchr(p + 1, '_');
	if(q == NULL) {
		printf("%s format is wrong.\n", filename);
		goto end;
	}
	*q = 0;
	//printf("%s,", p + 1);

	p = strchr(q + 1, '_');
	if(p == NULL) {
		printf("%s format is wrong.\n", filename);
		goto end;
	}
	*p = 0;
	//printf("llc%02dMB,", atoi(q + 1) / 2 * 9);
	//strncat(result, ",", sizeof(result) - 1);
	if(atoi(q + 1) == 0)
		snprintf(temp, sizeof(temp) - 1, "105,");
	else
		snprintf(temp, sizeof(temp) - 1, "%d,", atoi(q + 1) * 7);
	strncat(result, temp, sizeof(result) - 1);

	snprintf(temp, sizeof(temp) - 1, "%.5f,", latency / cnt);
	strncat(result, temp, sizeof(result) - 1);

	snprintf(temp, sizeof(temp) - 1, "%.2f,", total);
	strncat(result, temp, sizeof(result) - 1);

	snprintf(temp, sizeof(temp) - 1, "%.2f,", tps);
	strncat(result, temp, sizeof(result) - 1);

	if(*header == 0) {
		strncpy(header, "method,cores,cache size,latency,qps,tps,", sizeof(header) - 1);
		is_first = 1;
	}
	
	snprintf(filename, sizeof(filename) - 1, "%s/%s/__edp_socket_view_summary.csv", dirname, sub_dirname);
	if(stat(filename, &stbuf) < 0) {
		printf("stat %s failed.\n", filename);
		goto end;
	}

	fd = open(filename, O_RDONLY);
	if(fd < 0) {
		printf("open %s failed.\n", filename);
		goto end;
	}
	
	buf = (char *)malloc(stbuf.st_size + 1);
	if(buf == NULL) {
		printf("malloc failed.\n");
		goto end;
	}

	buf[stbuf.st_size] = 0;
	if(read(fd, buf, stbuf.st_size) != stbuf.st_size) {
		printf("read failed.\n");
		goto end;
	}

	q = buf;
	while(1) {
		p = strchr(q, '\n');
		if(p == NULL) {
			break;
		}

		q = strchr(p + 1, ',');
		if(q == NULL) {
			break;
		}
		*q = 0;
		if(is_first) {
			strncat(header, p + 1, sizeof(result) - 1);
			strncat(header, ",", sizeof(result) - 1);
		}

		p = strchr(q + 1, ',');
		if(p == NULL) {
			break;
		}

		*p = 0;
		strncat(result, q + 1, sizeof(result) - 1);
		strncat(result, ",", sizeof(result) - 1);
		q = p + 1;
	}
	result[strlen(result) - 1] = '\n';
	if(is_first)
		header[strlen(header) - 1] = '\n';

end:;
	return ret;
}
#endif
int check_dir(char *full_dirname)
{
	DIR *dp;
	struct dirent *de;
	int ret = 0;

	if((dp = opendir(full_dirname)) == NULL) {
		printf("opendir %s failed\n", full_dirname);
		return -1;
	}

	while((de = readdir(dp)) != NULL) {
		if( (strcmp(de->d_name, ".") == 0) || (strcmp(de->d_name, "..") == 0) )
			continue;

		if(check_resultdir(full_dirname, de->d_name) < 0) {
			ret = -1;
			break;
		}
	}
	
	printf("%s%s", header, result);
	closedir(dp);
		return ret;
}

int main(int argc, char** argv)
{
	if(argc != 2) {
		printf("parameter error.\n");
		return -1;
	}

	//g_str = argv[1];
	getcwd(g_rootdir, sizeof(g_rootdir));
	return check_dir(argv[1]);
}


