// Dump full sector 0 and sector at partition start
#include <femtorv32.h>

extern int sd_init(void);
extern int sd_readsector(uint32_t start_block, uint8_t *buffer, uint32_t sector_count);

static void out_hex8(uint8_t v) {
    int hi = (v >> 4) & 0xF, lo = v & 0xF;
    putchar(hi < 10 ? '0' + hi : 'A' + hi - 10);
    putchar(lo < 10 ? '0' + lo : 'A' + lo - 10);
}

static void dump_sector(uint8_t *buf, int rows) {
    for (int r = 0; r < rows; r++) {
        // Address
        out_hex8(r * 16 >> 8); out_hex8((r * 16) & 0xFF);
        putchar(':'); putchar(' ');
        for (int c = 0; c < 16; c++) {
            out_hex8(buf[r * 16 + c]);
            putchar(' ');
        }
        for (int c = 0; c < 16; c++) {
            uint8_t ch = buf[r * 16 + c];
            putchar((ch >= 0x20 && ch < 0x7F) ? ch : '.');
        }
        putchar('\r'); putchar('\n');
    }
}

int main(void) {
    printf("SD Sector Dump\r\n");

    if (sd_init()) {
        printf("SD init failed\r\n");
        return 1;
    }
    printf("SD OK\r\n\r\n");

    uint8_t buf[512];
    sd_readsector(0, buf, 1);

    printf("=== Sector 0 (MBR) ===\r\n");
    dump_sector(buf, 32);  // Full 512 bytes

    // Show partition table
    printf("\r\nPartition 1: type=0x%x start_lba=%d\r\n",
        buf[0x1C2],
        buf[0x1C6] | (buf[0x1C7]<<8) | (buf[0x1C8]<<16) | (buf[0x1C9]<<24));

    // Read first sector of partition 1
    uint32_t part_start = buf[0x1C6] | (buf[0x1C7]<<8) | (buf[0x1C8]<<16) | (buf[0x1C9]<<24);
    if (part_start > 0 && part_start < 100000) {
        sd_readsector(part_start, buf, 1);
        printf("\r\n=== Sector %d (Partition 1 boot sector) ===\r\n", part_start);
        dump_sector(buf, 4); // First 64 bytes
        // Show FAT type string at offset 54 or 82
        printf("FAT type at 54: %.8s\r\n", &buf[54]);
        printf("FAT type at 82: %.8s\r\n", &buf[82]);
    }

    return 0;
}
