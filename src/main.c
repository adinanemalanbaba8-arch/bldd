/*
 * bldd -- "ldd наоборот".
 *
 * По заданной разделяемой библиотеке находит в указанном каталоге все
 * ELF-исполняемые файлы, которые от неё зависят (через DT_NEEDED),
 * с проверкой совпадения архитектуры, и формирует отчёт.
 */

#include "elf_utils.h"
#include "scanner.h"
#include "report.h"

#include <dirent.h>
#include <getopt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define DEFAULT_LIBPATHS "/lib:/usr/lib:/lib/x86_64-linux-gnu:/usr/lib/x86_64-linux-gnu"
#define MAX_QUERY_LIBS 32

static void print_usage(const char *prog)
{
    printf(
        "bldd -- обратный ldd: поиск исполняемых файлов, зависящих от библиотеки\n\n"
        "ИСПОЛЬЗОВАНИЕ:\n"
        "  %s -l <библиотека[,библиотека2,...]> -d <каталог> [опции]\n\n"
        "ОБЯЗАТЕЛЬНЫЕ ПАРАМЕТРЫ:\n"
        "  -l, --lib <имя>        Искомая разделяемая библиотека (например, libc.so.6).\n"
        "                         Можно указать несколько через запятую.\n"
        "  -d, --dir <путь>       Каталог для рекурсивного сканирования.\n\n"
        "НЕОБЯЗАТЕЛЬНЫЕ ПАРАМЕТРЫ:\n"
        "  -f, --format <вид>     Формат отчёта: txt, html, json или all (по умолч. txt).\n"
        "  -o, --output <имя>     Базовое имя файла отчёта без расширения\n"
        "                         (по умолчанию: bldd_report).\n"
        "  -L, --libpaths <спис.> Пути поиска файла библиотеки на диске, через ':'\n"
        "                         (по умолчанию: %s).\n"
        "  -h, --help             Показать эту справку и выйти.\n\n"
        "ПРИМЕРЫ:\n"
        "  %s -l libc.so.6 -d /bin\n"
        "      Найти в /bin все программы, использующие libc.so.6, отчёт bldd_report.txt\n\n"
        "  %s -l libc.so.6,libm.so.6 -d /usr/bin -f all -o report_usrbin\n"
        "      Найти зависимости сразу от двух библиотек в /usr/bin,\n"
        "      сформировать report_usrbin.txt, .html и .json\n",
        prog, DEFAULT_LIBPATHS, prog, prog);
}

/* Ищет файл библиотеки lib_name в путях search_paths (список через ':').
   Возвращает 1 и заполняет out_path/out_info при успехе, иначе 0. */
static int resolve_library(const char *lib_name, const char *search_paths,
                            char *out_path, size_t out_path_size, elf_info_t *out_info)
{
    char paths_copy[1024];
    strncpy(paths_copy, search_paths, sizeof(paths_copy) - 1);
    paths_copy[sizeof(paths_copy) - 1] = '\0';

    char target_base[BLDD_MAX_NAME];
    elf_lib_basename_no_version(lib_name, target_base, sizeof(target_base));

    /* Простой перебор файлов каждого каталога через opendir/readdir */
    paths_copy[sizeof(paths_copy) - 1] = '\0';
    char *save;
    char *d = strtok_r(paths_copy, ":", &save);
    while (d != NULL) {
        char full[1024];
        /* попытка №1: точное имя файла */
        snprintf(full, sizeof(full), "%s/%s", d, lib_name);
        elf_parse_status_t st = elf_parse_file(full, out_info);
        if (st == ELF_PARSE_OK) {
            strncpy(out_path, full, out_path_size - 1);
            out_path[out_path_size - 1] = '\0';
            return 1;
        }
        d = strtok_r(NULL, ":", &save);
    }

    /* попытка №2: поиск по базовому имени без версии среди файлов каталога */
    strncpy(paths_copy, search_paths, sizeof(paths_copy) - 1);
    paths_copy[sizeof(paths_copy) - 1] = '\0';
    d = strtok_r(paths_copy, ":", &save);
    while (d != NULL) {
        DIR *dp = opendir(d);
        if (dp) {
            struct dirent *ent;
            while ((ent = readdir(dp)) != NULL) {
                char base[BLDD_MAX_NAME];
                elf_lib_basename_no_version(ent->d_name, base, sizeof(base));
                if (strcmp(base, target_base) == 0) {
                    char full[1024];
                    snprintf(full, sizeof(full), "%s/%s", d, ent->d_name);
                    if (elf_parse_file(full, out_info) == ELF_PARSE_OK) {
                        strncpy(out_path, full, out_path_size - 1);
                        out_path[out_path_size - 1] = '\0';
                        closedir(dp);
                        return 1;
                    }
                }
            }
            closedir(dp);
        }
        d = strtok_r(NULL, ":", &save);
    }

    return 0;
}

/* Проверяет, зависит ли exe от lib_name (точное совпадение или по базовому имени) */
static int exe_depends_on(const elf_info_t *exe, const char *lib_name)
{
    char target_base[BLDD_MAX_NAME];
    elf_lib_basename_no_version(lib_name, target_base, sizeof(target_base));

    for (int i = 0; i < exe->needed_count; i++) {
        if (strcmp(exe->needed[i], lib_name) == 0)
            return 1;
        char needed_base[BLDD_MAX_NAME];
        elf_lib_basename_no_version(exe->needed[i], needed_base, sizeof(needed_base));
        if (strcmp(needed_base, target_base) == 0)
            return 1;
    }
    return 0;
}

static int cmp_rows_desc(const void *a, const void *b)
{
    const report_exe_row_t *ra = a, *rb = b;
    if (rb->matched_libs != ra->matched_libs)
        return rb->matched_libs - ra->matched_libs;
    if (rb->total_needed != ra->total_needed)
        return rb->total_needed - ra->total_needed;
    return strcmp(ra->path, rb->path);
}

int main(int argc, char **argv)
{
    const char *lib_arg = NULL;
    const char *dir_arg = NULL;
    const char *format_arg = "txt";
    const char *output_arg = "bldd_report";
    const char *libpaths_arg = DEFAULT_LIBPATHS;

    static struct option long_opts[] = {
        {"lib",      required_argument, 0, 'l'},
        {"dir",      required_argument, 0, 'd'},
        {"format",   required_argument, 0, 'f'},
        {"output",   required_argument, 0, 'o'},
        {"libpaths", required_argument, 0, 'L'},
        {"help",     no_argument,       0, 'h'},
        {0, 0, 0, 0}
    };

    int opt;
    while ((opt = getopt_long(argc, argv, "l:d:f:o:L:h", long_opts, NULL)) != -1) {
        switch (opt) {
            case 'l': lib_arg = optarg; break;
            case 'd': dir_arg = optarg; break;
            case 'f': format_arg = optarg; break;
            case 'o': output_arg = optarg; break;
            case 'L': libpaths_arg = optarg; break;
            case 'h': print_usage(argv[0]); return 0;
            default:  print_usage(argv[0]); return 1;
        }
    }

    if (!lib_arg || !dir_arg) {
        fprintf(stderr, "Ошибка: обязательны параметры -l и -d.\n\n");
        print_usage(argv[0]);
        return 1;
    }

    /* 1. Сканирование каталога */
    exe_list_t list;
    exe_list_init(&list);
    int skipped = 0;
    if (scan_directory(dir_arg, &list, &skipped) != 0) {
        fprintf(stderr, "Ошибка: не удалось открыть каталог '%s'.\n", dir_arg);
        return 1;
    }

    int total_static = 0;
    for (int i = 0; i < list.count; i++)
        if (!list.items[i].info.has_dynamic)
            total_static++;

    /* 2. Разбор списка искомых библиотек (через запятую) */
    char libs_copy[1024];
    strncpy(libs_copy, lib_arg, sizeof(libs_copy) - 1);
    libs_copy[sizeof(libs_copy) - 1] = '\0';

    char *query_libs[MAX_QUERY_LIBS];
    int query_count = 0;
    char *save;
    char *tok = strtok_r(libs_copy, ",", &save);
    while (tok != NULL && query_count < MAX_QUERY_LIBS) {
        query_libs[query_count++] = tok;
        tok = strtok_r(NULL, ",", &save);
    }

    /* 3. Для каждой искомой библиотеки собираем список использующих её файлов */
    report_lib_result_t *lib_results = calloc((size_t)query_count, sizeof(report_lib_result_t));

    /* summary: суммарный счётчик "сколько искомых библиотек использует каждый exe" */
    int *summary_matches = calloc((size_t)list.count, sizeof(int));

    for (int q = 0; q < query_count; q++) {
        report_lib_result_t *lr = &lib_results[q];
        strncpy(lr->lib_name, query_libs[q], sizeof(lr->lib_name) - 1);

        elf_info_t lib_info;
        char lib_path[1024];
        lr->resolved = resolve_library(query_libs[q], libpaths_arg, lib_path, sizeof(lib_path), &lib_info);
        if (lr->resolved) {
            strncpy(lr->resolved_path, lib_path, sizeof(lr->resolved_path) - 1);
            strncpy(lr->resolved_arch, elf_machine_name(lib_info.e_machine), sizeof(lr->resolved_arch) - 1);
        }

        lr->rows = calloc((size_t)list.count, sizeof(report_exe_row_t));
        lr->row_count = 0;

        for (int i = 0; i < list.count; i++) {
            const exe_entry_t *e = &list.items[i];
            if (!e->info.has_dynamic)
                continue; /* статические файлы ни от чего не зависят */
            if (!exe_depends_on(&e->info, query_libs[q]))
                continue;

            /* Проверка архитектуры: если библиотека найдена на диске,
               засчитываем зависимость только при совпадении e_machine и разрядности */
            if (lr->resolved) {
                if (e->info.e_machine != lib_info.e_machine || e->info.elf_class != lib_info.elf_class)
                    continue;
            }

            report_exe_row_t *row = &lr->rows[lr->row_count++];
            strncpy(row->path, e->path, sizeof(row->path) - 1);
            strncpy(row->arch, elf_machine_name(e->info.e_machine), sizeof(row->arch) - 1);
            row->total_needed = e->info.needed_count;
            row->matched_libs = 1;

            summary_matches[i]++;
        }

        qsort(lr->rows, (size_t)lr->row_count, sizeof(report_exe_row_t), cmp_rows_desc);
    }

    /* 4. Итоговая (summary) таблица: все файлы, совпавшие хотя бы с одной библиотекой */
    report_exe_row_t *summary_rows = calloc((size_t)list.count, sizeof(report_exe_row_t));
    int summary_count = 0;
    for (int i = 0; i < list.count; i++) {
        if (summary_matches[i] == 0)
            continue;
        report_exe_row_t *row = &summary_rows[summary_count++];
        strncpy(row->path, list.items[i].path, sizeof(row->path) - 1);
        strncpy(row->arch, elf_machine_name(list.items[i].info.e_machine), sizeof(row->arch) - 1);
        row->total_needed = list.items[i].info.needed_count;
        row->matched_libs = summary_matches[i];
    }
    qsort(summary_rows, (size_t)summary_count, sizeof(report_exe_row_t), cmp_rows_desc);

    /* 5. Формирование данных отчёта и запись в выбранных форматах */
    report_data_t data;
    memset(&data, 0, sizeof(data));
    strncpy(data.scan_dir, dir_arg, sizeof(data.scan_dir) - 1);
    time_t now = time(NULL);
    strftime(data.generated_at, sizeof(data.generated_at), "%Y-%m-%d %H:%M:%S", localtime(&now));
    data.total_scanned = list.count;
    data.total_static = total_static;
    data.skipped_count = skipped;
    data.libs = lib_results;
    data.lib_count = query_count;
    data.summary_rows = summary_rows;
    data.summary_count = summary_count;

    int wrote_any = 0;
    char out_file[1100];
    if (strcmp(format_arg, "txt") == 0 || strcmp(format_arg, "all") == 0) {
        snprintf(out_file, sizeof(out_file), "%s.txt", output_arg);
        report_write_txt(&data, out_file);
        printf("Отчёт записан: %s\n", out_file);
        wrote_any = 1;
    }
    if (strcmp(format_arg, "html") == 0 || strcmp(format_arg, "all") == 0) {
        snprintf(out_file, sizeof(out_file), "%s.html", output_arg);
        report_write_html(&data, out_file);
        printf("Отчёт записан: %s\n", out_file);
        wrote_any = 1;
    }
    if (strcmp(format_arg, "json") == 0 || strcmp(format_arg, "all") == 0) {
        snprintf(out_file, sizeof(out_file), "%s.json", output_arg);
        report_write_json(&data, out_file);
        printf("Отчёт записан: %s\n", out_file);
        wrote_any = 1;
    }
    if (!wrote_any) {
        fprintf(stderr, "Ошибка: неизвестный формат отчёта '%s' (ожидается txt/html/json/all).\n", format_arg);
    }

    printf("\nПросканировано ELF-исполняемых файлов: %d (статических: %d), пропущено: %d\n",
           data.total_scanned, data.total_static, data.skipped_count);

    /* 6. Освобождение памяти */
    for (int q = 0; q < query_count; q++)
        free(lib_results[q].rows);
    free(lib_results);
    free(summary_rows);
    free(summary_matches);
    exe_list_free(&list);

    return wrote_any ? 0 : 1;
}

