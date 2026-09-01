#include <stddef.h>
#include <stdint.h>
#include <string.h>

#include <libdeflate.h>
#include <lsquic.h>
#include <openssl/sha.h>

static int check_sha256(void)
{
	static const uint8_t input[] = "uWebZockets-msan";
	uint8_t digest[SHA256_DIGEST_LENGTH] = { 0 };

	if (SHA256(input, sizeof(input) - 1, digest) == NULL)
		return 1;
	return digest[0] == 0 && digest[1] == 0;
}

static int check_deflate(void)
{
	static const uint8_t input[] =
		"bounded-memory-sanitizer-round-trip";
	uint8_t compressed[128] = { 0 };
	uint8_t output[sizeof(input)] = { 0 };
	struct libdeflate_compressor *compressor;
	struct libdeflate_decompressor *decompressor;
	size_t compressed_size;
	size_t output_size = 0;
	int failed = 1;

	compressor = libdeflate_alloc_compressor(6);
	decompressor = libdeflate_alloc_decompressor();
	if (compressor == NULL || decompressor == NULL)
		goto out;
	compressed_size = libdeflate_zlib_compress(compressor,
		input, sizeof(input), compressed, sizeof(compressed));
	if (compressed_size == 0)
		goto out;
	if (libdeflate_zlib_decompress(decompressor, compressed,
		compressed_size, output, sizeof(output), &output_size) !=
		LIBDEFLATE_SUCCESS)
		goto out;
	if (output_size != sizeof(input) || memcmp(input, output, sizeof(input)) != 0)
		goto out;
	failed = 0;

out:
	libdeflate_free_compressor(compressor);
	libdeflate_free_decompressor(decompressor);
	return failed;
}

static int check_lsquic_settings(void)
{
	struct lsquic_engine_settings settings;
	char error_buffer[256] = { 0 };

	memset(&settings, 0, sizeof(settings));
	lsquic_engine_init_settings(&settings, LSENG_HTTP_SERVER);
	return lsquic_engine_check_settings(&settings, LSENG_HTTP_SERVER,
		error_buffer, sizeof(error_buffer)) != 0;
}

int main(void)
{
	if (check_sha256() != 0)
		return 1;
	if (check_deflate() != 0)
		return 2;
	if (check_lsquic_settings() != 0)
		return 3;
	return 0;
}
