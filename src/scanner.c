#include "scanner.h"

#include <dirent.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

void exe_list_init(exe_list_t *list)
{
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

void exe_list_free(exe_list_t *list)
{
    free(list->items);
    list->items = NULL;
    list->count = 0;
    list->capacity = 0;
}

static void exe_list_push(exe_list_t *list, const char *path, const elf_info_t *info)
{
    if (list->count == list->capacity) {
        int new_cap = list->capacity == 0 ? 64 : list->capacity * 2;
        exe_entry_t *grown = realloc(list->items, (size_t)new_cap * sizeof(exe_entry_t));
        if (!grown)
            return; /* при нехватке памяти просто перестаём добавлять новые записи */
        list->items = grown;
        list->capacity = new_cap;
    }
    exe_entry_t *e = &list->items[list->count++];
    strncpy(e->path, path, sizeof(e->path) - 1);
    e->path[sizeof(e->path) - 1] = '\0';
    e->info = *info;
}

/* Рекурсивный обходчик. Использует lstat, чтобы не заходить по симлинкам. */
static void scan_recursive(const char *dir_path, exe_list_t *list, int *skipped_count)
{
    DIR *dir = opendir(dir_path);
    if (!dir) {
        if (skipped_count) (*skipped_count)++;
        return;
    }

    struct dirent *entry;
    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0)
            continue;

        char full_path[PATH_MAX];
        int written = snprintf(full_path, sizeof(full_path), "%s/%s", dir_path, entry->d_name);
        if (written < 0 || (size_t)written >= sizeof(full_path)) {
            if (skipped_count) (*skipped_count)++;
            continue; /* путь слишком длинный -- пропускаем, не падаем */
        }

        struct stat st;
        if (lstat(full_path, &st) != 0) {
            if (skipped_count) (*skipped_count)++;
            continue; /* например, битая ссылка или файл исчез между readdir/lstat */
        }

        if (S_ISLNK(st.st_mode)) {
            /* символические ссылки сознательно пропускаем: не проверяем, куда
               они ведут, чтобы не зациклиться и не задвоить файлы */
            continue;
        }

        if (S_ISDIR(st.st_mode)) {
            scan_recursive(full_path, list, skipped_count);
            continue;
        }

        if (!S_ISREG(st.st_mode))
            continue; /* устройства, сокеты и т.п. нас не интересуют */

        if (access(full_path, R_OK) != 0) {
            if (skipped_count) (*skipped_count)++;
            continue; /* нет прав на чтение -- пропускаем, логируем через счётчик */
        }

        elf_info_t info;
        elf_parse_status_t status = elf_parse_file(full_path, &info);
        if (status != ELF_PARSE_OK)
            continue; /* не ELF, либо не удалось прочитать -- тихо пропускаем */

        if (elf_is_executable(&info))
            exe_list_push(list, full_path, &info);
    }

    closedir(dir);
}

int scan_directory(const char *root_dir, exe_list_t *list, int *skipped_count)
{
    struct stat st;
    if (stat(root_dir, &st) != 0 || !S_ISDIR(st.st_mode))
        return -1;

    scan_recursive(root_dir, list, skipped_count);
    return 0;
}

