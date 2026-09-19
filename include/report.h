#ifndef BLDD_REPORT_H
#define BLDD_REPORT_H

#include <limits.h>

/* Один исполняемый файл, найденный зависящим от искомой библиотеки */
typedef struct {
    char path[PATH_MAX];
    char arch[64];
    int  total_needed;   /* сколько всего библиотек нужно этому файлу */
    int  matched_libs;   /* сколько из ИСКОМЫХ библиотек он использует */
} report_exe_row_t;

/* Результат по одной искомой библиотеке: сама библиотека + кто её использует */
typedef struct {
    char               lib_name[256];
    int                resolved;         /* удалось ли найти файл библиотеки на диске */
    char               resolved_path[PATH_MAX];
    char               resolved_arch[64];
    report_exe_row_t  *rows;
    int                row_count;
} report_lib_result_t;

typedef struct {
    char                  scan_dir[PATH_MAX];
    char                  generated_at[64];
    int                   total_scanned;      /* всего найдено ELF-исполняемых файлов */
    int                   total_static;       /* из них статически слинкованных */
    int                   skipped_count;      /* пропущено из-за ошибок доступа/чтения */
    report_lib_result_t  *libs;
    int                   lib_count;
    report_exe_row_t     *summary_rows;       /* объединённый список по всем библиотекам */
    int                   summary_count;
} report_data_t;

int report_write_txt(const report_data_t *data, const char *out_path);
int report_write_html(const report_data_t *data, const char *out_path);
int report_write_json(const report_data_t *data, const char *out_path);

#endif /* BLDD_REPORT_H */

