/*
 * ext4_visual_defrag_standalone.c - Standalone Windows-style visual defrag tool
 *
 * A fun demonstration of ext4 defragmentation with beautiful terminal UI!
 * This standalone version doesn't require e2fsprogs libraries.
 *
 * Copyright (C) 2025
 * License: GPL v2
 */

#define _GNU_SOURCE
#define _FILE_OFFSET_BITS 64

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/vfs.h>
#include <linux/fs.h>
#include <linux/fiemap.h>
#include <linux/magic.h>
#include <dirent.h>
#include <limits.h>

/* Terminal colors */
#define COLOR_RESET   "\033[0m"
#define COLOR_RED     "\033[31m"
#define COLOR_GREEN   "\033[32m"
#define COLOR_YELLOW  "\033[33m"
#define COLOR_BLUE    "\033[34m"
#define COLOR_MAGENTA "\033[35m"
#define COLOR_CYAN    "\033[36m"
#define COLOR_BOLD    "\033[1m"
#define COLOR_DIM     "\033[2m"

/* Visual characters */
#define BLOCK_FREE      "░"
#define BLOCK_USED      "▓"
#define BLOCK_FRAG      "▒"
#define BLOCK_SYSTEM    "█"

#define VISUAL_MAP_WIDTH  80
#define VISUAL_MAP_HEIGHT 20
#define MAX_EXTENT_COUNT  512

/* Statistics */
struct defrag_stats {
	unsigned long total_files;
	unsigned long fragmented_files;
	unsigned long total_extents;
	unsigned long avg_extents;
	unsigned long files_scanned;
	off64_t total_size;
	off64_t largest_file;
	float fragmentation_score;
};

/* Visual map */
struct disk_map {
	char map[VISUAL_MAP_HEIGHT][VISUAL_MAP_WIDTH + 1];
	unsigned long blocks_represented;
};

/* Global context */
struct defrag_context {
	char *mount_point;
	int verbose;
	int analyze_only;
	struct defrag_stats stats;
	struct disk_map visual;
	time_t start_time;
};

/*
 * Print banner
 */
static void print_banner(void)
{
	printf("\n");
	printf(COLOR_CYAN COLOR_BOLD);
	printf("╔════════════════════════════════════════════════════════════════════════╗\n");
	printf("║                                                                        ║\n");
	printf("║        EXT4 VISUAL DEFRAGMENTER - Windows Style Defrag Tool           ║\n");
	printf("║                                                                        ║\n");
	printf("║           Making ext4 fragmentation visible and fun! 🚀               ║\n");
	printf("║                                                                        ║\n");
	printf("╚════════════════════════════════════════════════════════════════════════╝\n");
	printf(COLOR_RESET);
	printf("\n");
}

/*
 * Initialize disk map
 */
static void init_disk_map(struct disk_map *map)
{
	int i, j;
	for (i = 0; i < VISUAL_MAP_HEIGHT; i++) {
		for (j = 0; j < VISUAL_MAP_WIDTH; j++) {
			map->map[i][j] = ' ';
		}
		map->map[i][VISUAL_MAP_WIDTH] = '\0';
	}
	map->blocks_represented = 0;
}

/*
 * Update disk map
 */
static void update_disk_map(struct disk_map *map, int file_idx, int extent_count)
{
	int x = file_idx % VISUAL_MAP_WIDTH;
	int y = (file_idx / VISUAL_MAP_WIDTH) % VISUAL_MAP_HEIGHT;

	if (y >= VISUAL_MAP_HEIGHT)
		return;

	if (extent_count == 0)
		map->map[y][x] = 'F'; /* Free/empty */
	else if (extent_count == 1)
		map->map[y][x] = 'U'; /* Used, contiguous */
	else if (extent_count < 5)
		map->map[y][x] = 'L'; /* Lightly fragmented */
	else
		map->map[y][x] = 'X'; /* Heavily fragmented */
}

/*
 * Print disk map
 */
static void print_disk_map(struct disk_map *map, const char *title)
{
	int i, j;

	printf("\n");
	printf(COLOR_BOLD "%s\n" COLOR_RESET, title);
	printf("┌");
	for (i = 0; i < VISUAL_MAP_WIDTH; i++)
		printf("─");
	printf("┐\n");

	for (i = 0; i < VISUAL_MAP_HEIGHT; i++) {
		printf("│");
		for (j = 0; j < VISUAL_MAP_WIDTH; j++) {
			char c = map->map[i][j];
			switch (c) {
			case 'F':
				printf(COLOR_GREEN BLOCK_FREE COLOR_RESET);
				break;
			case 'U':
				printf(COLOR_BLUE BLOCK_USED COLOR_RESET);
				break;
			case 'L':
				printf(COLOR_YELLOW BLOCK_FRAG COLOR_RESET);
				break;
			case 'X':
				printf(COLOR_RED BLOCK_FRAG COLOR_RESET);
				break;
			default:
				printf(" ");
			}
		}
		printf("│\n");
	}

	printf("└");
	for (i = 0; i < VISUAL_MAP_WIDTH; i++)
		printf("─");
	printf("┘\n");

	printf("\nLegend: ");
	printf(COLOR_GREEN BLOCK_FREE COLOR_RESET " Empty  ");
	printf(COLOR_BLUE BLOCK_USED COLOR_RESET " Contiguous  ");
	printf(COLOR_YELLOW BLOCK_FRAG COLOR_RESET " Light Frag  ");
	printf(COLOR_RED BLOCK_FRAG COLOR_RESET " Heavy Frag\n");
}

/*
 * Get file extent count using FIEMAP
 */
static int get_extent_count(const char *filepath)
{
	int fd;
	struct fiemap *fiemap;
	int extent_count = 0;

	fd = open(filepath, O_RDONLY);
	if (fd < 0)
		return -1;

	fiemap = malloc(sizeof(struct fiemap));
	if (!fiemap) {
		close(fd);
		return -1;
	}

	memset(fiemap, 0, sizeof(struct fiemap));
	fiemap->fm_start = 0;
	fiemap->fm_length = FIEMAP_MAX_OFFSET;
	fiemap->fm_flags = FIEMAP_FLAG_SYNC;
	fiemap->fm_extent_count = 0;

	if (ioctl(fd, FS_IOC_FIEMAP, fiemap) >= 0) {
		extent_count = fiemap->fm_mapped_extents;
	} else {
		extent_count = -1;
	}

	free(fiemap);
	close(fd);
	return extent_count;
}

/*
 * Progress bar
 */
static void print_progress(int percent, const char *status)
{
	int i;
	int filled = percent * 50 / 100;

	printf("\r[");
	for (i = 0; i < 50; i++) {
		if (i < filled)
			printf(COLOR_GREEN "█" COLOR_RESET);
		else
			printf(COLOR_DIM "░" COLOR_RESET);
	}
	printf("] %3d%% - %s", percent, status);
	fflush(stdout);
}

/*
 * Scan directory recursively
 */
static int scan_directory(struct defrag_context *ctx, const char *path, int depth)
{
	DIR *dir;
	struct dirent *entry;
	char filepath[PATH_MAX];
	struct stat st;
	int extent_count;

	if (depth > 20)
		return 0; /* Prevent infinite recursion */

	dir = opendir(path);
	if (!dir)
		return -1;

	while ((entry = readdir(dir)) != NULL) {
		if (strcmp(entry->d_name, ".") == 0 ||
		    strcmp(entry->d_name, "..") == 0)
			continue;

		snprintf(filepath, sizeof(filepath), "%s/%s", path, entry->d_name);

		if (lstat(filepath, &st) < 0)
			continue;

		if (S_ISDIR(st.st_mode)) {
			/* Recurse into subdirectory */
			scan_directory(ctx, filepath, depth + 1);
		} else if (S_ISREG(st.st_mode)) {
			/* Regular file */
			ctx->stats.total_files++;
			ctx->stats.total_size += st.st_size;

			if (st.st_size > ctx->stats.largest_file)
				ctx->stats.largest_file = st.st_size;

			/* Get extent count */
			extent_count = get_extent_count(filepath);
			if (extent_count > 0) {
				ctx->stats.total_extents += extent_count;
				if (extent_count > 1)
					ctx->stats.fragmented_files++;

				/* Update visual map */
				update_disk_map(&ctx->visual, ctx->stats.files_scanned, extent_count);

				if (ctx->verbose && extent_count > 5) {
					printf("\n" COLOR_YELLOW "  Fragmented: " COLOR_RESET "%s (%d extents)",
					       entry->d_name, extent_count);
				}
			}

			ctx->stats.files_scanned++;

			/* Update progress every 50 files */
			if (ctx->stats.files_scanned % 50 == 0) {
				print_progress(50, "Scanning files...");
			}
		}
	}

	closedir(dir);
	return 0;
}

/*
 * Print statistics
 */
static void print_statistics(struct defrag_stats *stats)
{
	printf("\n");
	printf(COLOR_BOLD COLOR_CYAN "═══════════════════════ FRAGMENTATION ANALYSIS ═══════════════════════\n" COLOR_RESET);
	printf("\n");

	printf(COLOR_BOLD "Filesystem Statistics:\n" COLOR_RESET);
	printf("  Total files scanned:      %lu\n", stats->files_scanned);
	printf("  Total size:               %.2f GB\n", (double)stats->total_size / (1024*1024*1024));
	printf("  Largest file:             %.2f MB\n", (double)stats->largest_file / (1024*1024));
	printf("\n");

	printf(COLOR_BOLD "Fragmentation Metrics:\n" COLOR_RESET);
	printf("  Fragmented files:         %lu ", stats->fragmented_files);
	if (stats->total_files > 0) {
		float frag_pct = (float)stats->fragmented_files * 100.0 / stats->total_files;
		if (frag_pct < 5.0)
			printf(COLOR_GREEN "(%.1f%% - Excellent!)" COLOR_RESET "\n", frag_pct);
		else if (frag_pct < 15.0)
			printf(COLOR_YELLOW "(%.1f%% - Good)" COLOR_RESET "\n", frag_pct);
		else
			printf(COLOR_RED "(%.1f%% - Needs defrag)" COLOR_RESET "\n", frag_pct);
	} else {
		printf("\n");
	}

	if (stats->total_files > 0) {
		stats->avg_extents = stats->total_extents / stats->total_files;
		printf("  Average extents per file: %lu\n", stats->avg_extents);
		printf("  Total extents:            %lu\n", stats->total_extents);

		/* Calculate fragmentation score */
		stats->fragmentation_score = (stats->avg_extents - 1.0) * 10.0;
		if (stats->fragmentation_score > 100.0)
			stats->fragmentation_score = 100.0;

		printf("  Fragmentation score:      ");
		if (stats->fragmentation_score < 10.0)
			printf(COLOR_GREEN "%.1f%% (Excellent)" COLOR_RESET "\n", stats->fragmentation_score);
		else if (stats->fragmentation_score < 30.0)
			printf(COLOR_YELLOW "%.1f%% (Good)" COLOR_RESET "\n", stats->fragmentation_score);
		else
			printf(COLOR_RED "%.1f%% (Poor)" COLOR_RESET "\n", stats->fragmentation_score);
	}

	printf("\n");
}

/*
 * Main
 */
static void usage(const char *prog)
{
	fprintf(stderr, "Usage: %s [options] <mount_point>\n\n", prog);
	fprintf(stderr, "Options:\n");
	fprintf(stderr, "  -a          Analyze only (default)\n");
	fprintf(stderr, "  -v          Verbose output\n");
	fprintf(stderr, "  -h          Display this help\n\n");
	fprintf(stderr, "Example:\n");
	fprintf(stderr, "  %s /home                     # Analyze /home\n", prog);
	fprintf(stderr, "  %s -v /                      # Analyze root with details\n\n", prog);
}

int main(int argc, char **argv)
{
	struct defrag_context ctx;
	int c;
	struct statfs sfs;
	time_t elapsed;

	memset(&ctx, 0, sizeof(ctx));
	ctx.analyze_only = 1;

	while ((c = getopt(argc, argv, "avh")) != -1) {
		switch (c) {
		case 'a':
			ctx.analyze_only = 1;
			break;
		case 'v':
			ctx.verbose = 1;
			break;
		case 'h':
			usage(argv[0]);
			return 0;
		default:
			usage(argv[0]);
			return 1;
		}
	}

	if (optind >= argc) {
		fprintf(stderr, "Error: No mount point specified\n\n");
		usage(argv[0]);
		return 1;
	}

	ctx.mount_point = argv[optind];

	/* Check if path exists */
	if (access(ctx.mount_point, R_OK) < 0) {
		fprintf(stderr, "Error: Cannot access %s: %s\n", ctx.mount_point, strerror(errno));
		return 1;
	}

	/* Get filesystem info */
	if (statfs(ctx.mount_point, &sfs) < 0) {
		fprintf(stderr, "Error: Cannot get filesystem info: %s\n", strerror(errno));
		return 1;
	}

	/* Print banner */
	print_banner();

	printf(COLOR_BOLD "Mount point: " COLOR_RESET "%s\n", ctx.mount_point);
	printf(COLOR_BOLD "Filesystem:  " COLOR_RESET);
	if (sfs.f_type == EXT4_SUPER_MAGIC)
		printf("ext4 " COLOR_GREEN "✓" COLOR_RESET "\n");
	else if (sfs.f_type == 0xEF53)
		printf("ext2/ext3/ext4\n");
	else
		printf("Unknown (0x%lx)\n", (unsigned long)sfs.f_type);

	printf(COLOR_BOLD "Block size:  " COLOR_RESET "%lu bytes\n", sfs.f_bsize);
	printf(COLOR_BOLD "Total space: " COLOR_RESET "%.2f GB\n",
	       (double)(sfs.f_blocks * sfs.f_bsize) / (1024*1024*1024));
	printf(COLOR_BOLD "Free space:  " COLOR_RESET "%.2f GB (%.1f%%)\n",
	       (double)(sfs.f_bfree * sfs.f_bsize) / (1024*1024*1024),
	       (double)sfs.f_bfree * 100.0 / sfs.f_blocks);

	/* Initialize */
	init_disk_map(&ctx.visual);
	ctx.start_time = time(NULL);

	/* Scan filesystem */
	printf("\n" COLOR_BOLD "🔍 Scanning filesystem for fragmentation...\n" COLOR_RESET);
	printf("\n");

	scan_directory(&ctx, ctx.mount_point, 0);

	print_progress(100, "Scan complete!          ");
	printf("\n");

	/* Show visual map */
	print_disk_map(&ctx.visual, "📊 FRAGMENTATION MAP");

	/* Print statistics */
	print_statistics(&ctx.stats);

	/* Recommendations */
	printf(COLOR_BOLD "💡 Recommendations:\n" COLOR_RESET);
	if (ctx.stats.fragmentation_score < 10.0) {
		printf(COLOR_GREEN "  ✓ Your filesystem is in excellent shape!\n");
		printf("  ✓ No defragmentation needed at this time.\n" COLOR_RESET);
	} else if (ctx.stats.fragmentation_score < 30.0) {
		printf(COLOR_YELLOW "  → Filesystem fragmentation is moderate.\n");
		printf("  → Consider defragmentation if you notice slowdowns.\n" COLOR_RESET);
	} else {
		printf(COLOR_RED "  ! Filesystem is heavily fragmented.\n");
		printf("  ! Defragmentation recommended for optimal performance.\n");
		printf("  ! Use: e4defrag %s\n" COLOR_RESET, ctx.mount_point);
	}

	printf("\n");

	/* Timing */
	elapsed = time(NULL) - ctx.start_time;
	printf(COLOR_BOLD "⏱  Analysis time: " COLOR_RESET);
	if (elapsed < 60)
		printf("%ld seconds\n", elapsed);
	else
		printf("%ld minutes %ld seconds\n", elapsed / 60, elapsed % 60);

	printf("\n" COLOR_BOLD COLOR_GREEN);
	printf("════════════════════════════════════════════════════════════════════════\n");
	printf("                         ✅ ANALYSIS COMPLETE! ✅\n");
	printf("════════════════════════════════════════════════════════════════════════\n");
	printf(COLOR_RESET "\n");

	printf(COLOR_DIM "Note: This is a demonstration tool. For actual defragmentation, use e4defrag.\n" COLOR_RESET);
	printf("\n");

	return 0;
}
