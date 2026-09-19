#ifndef BLDD_SCANNER_H
#define BLDD_SCANNER_H

#include "elf_utils.h"
#include <limits.h>

/* Один найденный исполняемый ELF-файл вместе с его разобранными заголовками */
typedef struct {
    char       path[PATH_MAX];
    elf_info_t info;
} exe_entry_t;

/* Динамический массив найденных исполняемых файлов */
typedef struct {
    exe_entry_t *items;
    int          count;
    int          capacity;
} exe_list_t;

void exe_list_init(exe_list_t *list);
void exe_list_free(exe_list_t *list);

/*
 * Рекурсивно обходит каталог root_dir, пропускает символические ссылки
 * (во избежание циклов) и файлы без прав на чтение, и складывает в list
 * все файлы, которые по заголовкам являются ELF-исполняемыми
 * (см. elf_is_executable). Статически слинкованные исполняемые файлы
 * также попадают в список (has_dynamic == 0), но без зависимостей.
 *
 * Возвращает 0 при успехе, -1 если сам root_dir недоступен.
 * Ошибки на отдельных файлах/подкаталогах не прерывают обход -- они
 * пропускаются, счётчик skipped_count (если не NULL) увеличивается.
 */
int scan_directory(const char *root_dir, exe_list_t *list, int *skipped_count);

#endif /* BLDD_SCANNER_H */

