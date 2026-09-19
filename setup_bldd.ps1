# Script de creation du projet bldd - a coller entierement dans PowerShell
New-Item -ItemType Directory -Force -Path "src" | Out-Null
New-Item -ItemType Directory -Force -Path "include" | Out-Null

Set-Content -Path "Makefile" -Value @'
CC      = gcc
CFLAGS  = -std=c11 -D_DEFAULT_SOURCE -Wall -Wextra -Iinclude -O2
SRC     = src/main.c src/elf_utils.c src/scanner.c src/report.c
BIN     = bldd

.PHONY: all clean

all: $(BIN)

$(BIN): $(SRC)
	$(CC) $(CFLAGS) -o $(BIN) $(SRC)

clean:
	rm -f $(BIN) *.txt *.html *.json

'@

Set-Content -Path "README.md" -Value @'
# bldd — обратный ldd

Консольная утилита на языке C для лабораторной работы «Анализ динамических
зависимостей ELF» (дисциплина «Разработка операционных систем»).

`ldd` отвечает на вопрос «какие библиотеки нужны этому исполняемому файлу?».
`bldd` решает обратную задачу: по заданной разделяемой библиотеке находит
все исполняемые ELF-файлы в указанном каталоге, которые от неё зависят.

## Сборка

```bash
make
```

Требуется компилятор gcc и системный заголовок `<elf.h>` (входит в состав
glibc на любом Linux/WSL).

## Использование

```bash
./bldd -l <библиотека[,библиотека2,...]> -d <каталог> [опции]
```

Полный список опций: `./bldd -h`.

Примеры:

```bash
./bldd -l libc.so.6 -d /bin
./bldd -l libc.so.6,libm.so.6 -d /usr/bin -f all -o report_usrbin
```

## Архитектура решения

| Модуль            | Назначение                                                          |
|-------------------|----------------------------------------------------------------------|
| `elf_utils.c/h`   | Разбор ELF-заголовка, Program Header Table и секции `.dynamic`      |
| `scanner.c/h`     | Рекурсивный обход каталога, отбор ELF-исполняемых файлов            |
| `report.c/h`      | Формирование отчёта в форматах `.txt`, `.html`, `.json`             |
| `main.c`          | Разбор аргументов командной строки, сопоставление и агрегация      |

Зависимости извлекаются из сегмента `PT_DYNAMIC` (Program Header Table),
а не из таблицы заголовков секций, так как последняя может быть удалена
или изменена (в т.ч. при обфускации), в то время как program headers
обязательны для работы системного загрузчика.

Признак исполняемого файла (а не разделяемой библиотеки): тип `ET_EXEC`,
либо `ET_DYN` при наличии сегмента `PT_INTERP` (PIE-исполняемый файл).

## Тестирование

Корректность извлечения зависимостей проверена сравнением с `readelf -d`
и `objdump -p` на системных бинарных файлах (`/bin`, `/usr/bin`).
Отдельно проверены: обработка статически слинкованных файлов,
циклических символических ссылок и файлов без прав на чтение.

'@

Set-Content -Path ".gitignore" -Value @'
bldd
*.o
*.txt
*.html
*.json
!README.md

'@

Set-Content -Path "include/elf_utils.h" -Value @'
#ifndef BLDD_ELF_UTILS_H
#define BLDD_ELF_UTILS_H

#include <stdint.h>
#include <stddef.h>

#define BLDD_MAX_NEEDED 128   /* максимум записей DT_NEEDED на файл */
#define BLDD_MAX_NAME   256   /* максимальная длина имени библиотеки */

/*
 * Информация об одном ELF-файле, извлечённая из заголовков.
 * Заполняется функцией elf_parse_file().
 */
typedef struct {
    int      elf_class;     /* 32 или 64 (разрядность ELF) */
    uint16_t e_type;        /* ET_EXEC, ET_DYN, ET_REL, ... */
    uint16_t e_machine;     /* архитектура: EM_X86_64, EM_386, EM_ARM, ... */
    int      has_interp;    /* 1, если в Program Header Table есть PT_INTERP */
    int      has_dynamic;   /* 1, если есть сегмент PT_DYNAMIC (.dynamic) */
    int      needed_count;
    char     needed[BLDD_MAX_NEEDED][BLDD_MAX_NAME]; /* строки DT_NEEDED */
} elf_info_t;

/* Результат попытки разбора файла как ELF */
typedef enum {
    ELF_PARSE_OK = 0,
    ELF_PARSE_NOT_ELF,      /* нет сигнатуры 0x7F 'E' 'L' 'F' */
    ELF_PARSE_IO_ERROR,     /* не удалось открыть/прочитать файл */
    ELF_PARSE_UNSUPPORTED   /* неизвестный класс ELF или битые заголовки */
} elf_parse_status_t;

/*
 * Разбирает ELF-заголовок, таблицу программных заголовков и (если есть)
 * динамический раздел файла path. Работает напрямую с файлом на диске
 * (не отображает его в память), поэтому не запускает и не исполняет код.
 */
elf_parse_status_t elf_parse_file(const char *path, elf_info_t *out);

/* Признак того, что файл по заголовкам является исполняемым, а не .so */
int elf_is_executable(const elf_info_t *info);

/* Человекочитаемое имя архитектуры по значению e_machine */
const char *elf_machine_name(uint16_t e_machine);

/*
 * Базовое имя разделяемой библиотеки без версионного суффикса.
 * Пример: "libc.so.6" -> "libc.so"; "libfoo.so" -> "libfoo.so" (без изменений).
 */
void elf_lib_basename_no_version(const char *name, char *out, size_t out_size);

/* Строковое имя типа файла (ET_EXEC / ET_DYN / ...) для отчёта */
const char *elf_type_name(uint16_t e_type);

#endif /* BLDD_ELF_UTILS_H */

'@

Set-Content -Path "include/scanner.h" -Value @'
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

'@

Set-Content -Path "include/report.h" -Value @'
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

'@

Set-Content -Path "src/elf_utils.c" -Value @'
#include "elf_utils.h"

#include <elf.h>
#include <stdio.h>
#include <string.h>

#define BLDD_MAX_PHDRS 128 /* достаточно для любых реальных бинарников ОС */

/* Внутреннее представление одного program header в "разрядно-независимом" виде */
typedef struct {
    uint32_t p_type;
    uint64_t p_offset;
    uint64_t p_vaddr;
    uint64_t p_filesz;
} generic_phdr_t;

/* Читает n байт по заданному смещению файла. Возвращает 0 при успехе. */
static int read_at(FILE *f, long offset, void *buf, size_t n)
{
    if (fseek(f, offset, SEEK_SET) != 0)
        return -1;
    if (fread(buf, 1, n, f) != n)
        return -1;
    return 0;
}

/* Преобразует виртуальный адрес в файловое смещение через таблицу PT_LOAD */
static int vaddr_to_offset(const generic_phdr_t *phdrs, int phnum,
                            uint64_t vaddr, uint64_t *out_offset)
{
    for (int i = 0; i < phnum; i++) {
        if (phdrs[i].p_type != PT_LOAD)
            continue;
        if (vaddr >= phdrs[i].p_vaddr &&
            vaddr < phdrs[i].p_vaddr + phdrs[i].p_filesz) {
            *out_offset = phdrs[i].p_offset + (vaddr - phdrs[i].p_vaddr);
            return 0;
        }
    }
    return -1;
}

/* Читает C-строку (до '\0') по файловому смещению, с ограничением длины */
static int read_cstring_at(FILE *f, long offset, char *out, size_t out_size)
{
    if (fseek(f, offset, SEEK_SET) != 0)
        return -1;
    size_t i = 0;
    while (i + 1 < out_size) {
        int c = fgetc(f);
        if (c == EOF)
            return -1;
        if (c == '\0')
            break;
        out[i++] = (char)c;
    }
    out[i] = '\0';
    return 0;
}

/* Разбор динамического раздела (PT_DYNAMIC) для 64-битного ELF */
static void parse_dynamic64(FILE *f, uint64_t dyn_off, uint64_t dyn_size,
                             const generic_phdr_t *phdrs, int phnum,
                             elf_info_t *out)
{
    int entries = (int)(dyn_size / sizeof(Elf64_Dyn));
    uint64_t strtab_vaddr = 0;
    int have_strtab = 0;

    /* Первый проход: ищем DT_STRTAB, параллельно запоминаем DT_NEEDED offsets */
    uint64_t needed_str_offsets[BLDD_MAX_NEEDED];
    int needed_raw_count = 0;

    for (int i = 0; i < entries; i++) {
        Elf64_Dyn dyn;
        if (read_at(f, (long)(dyn_off + i * sizeof(Elf64_Dyn)), &dyn, sizeof(dyn)) != 0)
            break;
        if (dyn.d_tag == DT_NULL)
            break;
        if (dyn.d_tag == DT_STRTAB) {
            strtab_vaddr = dyn.d_un.d_val;
            have_strtab = 1;
        } else if (dyn.d_tag == DT_NEEDED && needed_raw_count < BLDD_MAX_NEEDED) {
            needed_str_offsets[needed_raw_count++] = dyn.d_un.d_val;
        }
    }

    if (!have_strtab)
        return; /* без таблицы строк имена NEEDED прочитать нельзя */

    uint64_t strtab_file_off;
    if (vaddr_to_offset(phdrs, phnum, strtab_vaddr, &strtab_file_off) != 0)
        return;

    for (int i = 0; i < needed_raw_count; i++) {
        char name[BLDD_MAX_NAME];
        if (read_cstring_at(f, (long)(strtab_file_off + needed_str_offsets[i]),
                             name, sizeof(name)) == 0) {
            strncpy(out->needed[out->needed_count], name, BLDD_MAX_NAME - 1);
            out->needed[out->needed_count][BLDD_MAX_NAME - 1] = '\0';
            out->needed_count++;
        }
    }
}

/* Та же логика для 32-битного ELF (структуры Elf32_Dyn) */
static void parse_dynamic32(FILE *f, uint64_t dyn_off, uint64_t dyn_size,
                             const generic_phdr_t *phdrs, int phnum,
                             elf_info_t *out)
{
    int entries = (int)(dyn_size / sizeof(Elf32_Dyn));
    uint64_t strtab_vaddr = 0;
    int have_strtab = 0;

    uint64_t needed_str_offsets[BLDD_MAX_NEEDED];
    int needed_raw_count = 0;

    for (int i = 0; i < entries; i++) {
        Elf32_Dyn dyn;
        if (read_at(f, (long)(dyn_off + i * sizeof(Elf32_Dyn)), &dyn, sizeof(dyn)) != 0)
            break;
        if (dyn.d_tag == DT_NULL)
            break;
        if (dyn.d_tag == DT_STRTAB) {
            strtab_vaddr = dyn.d_un.d_val;
            have_strtab = 1;
        } else if (dyn.d_tag == DT_NEEDED && needed_raw_count < BLDD_MAX_NEEDED) {
            needed_str_offsets[needed_raw_count++] = dyn.d_un.d_val;
        }
    }

    if (!have_strtab)
        return;

    uint64_t strtab_file_off;
    if (vaddr_to_offset(phdrs, phnum, strtab_vaddr, &strtab_file_off) != 0)
        return;

    for (int i = 0; i < needed_raw_count; i++) {
        char name[BLDD_MAX_NAME];
        if (read_cstring_at(f, (long)(strtab_file_off + needed_str_offsets[i]),
                             name, sizeof(name)) == 0) {
            strncpy(out->needed[out->needed_count], name, BLDD_MAX_NAME - 1);
            out->needed[out->needed_count][BLDD_MAX_NAME - 1] = '\0';
            out->needed_count++;
        }
    }
}

elf_parse_status_t elf_parse_file(const char *path, elf_info_t *out)
{
    memset(out, 0, sizeof(*out));

    FILE *f = fopen(path, "rb");
    if (!f)
        return ELF_PARSE_IO_ERROR;

    unsigned char e_ident[EI_NIDENT];
    if (fread(e_ident, 1, EI_NIDENT, f) != EI_NIDENT) {
        fclose(f);
        return ELF_PARSE_NOT_ELF;
    }
    if (memcmp(e_ident, ELFMAG, SELFMAG) != 0) {
        fclose(f);
        return ELF_PARSE_NOT_ELF;
    }

    generic_phdr_t phdrs[BLDD_MAX_PHDRS];
    int phnum = 0;
    uint64_t dyn_off = 0, dyn_size = 0;
    int has_dynamic_segment = 0;

    if (e_ident[EI_CLASS] == ELFCLASS64) {
        Elf64_Ehdr ehdr;
        if (read_at(f, 0, &ehdr, sizeof(ehdr)) != 0) {
            fclose(f);
            return ELF_PARSE_UNSUPPORTED;
        }
        out->elf_class = 64;
        out->e_type = ehdr.e_type;
        out->e_machine = ehdr.e_machine;

        int n = ehdr.e_phnum;
        if (n > BLDD_MAX_PHDRS)
            n = BLDD_MAX_PHDRS;
        for (int i = 0; i < n; i++) {
            Elf64_Phdr ph;
            if (read_at(f, (long)(ehdr.e_phoff + (uint64_t)i * ehdr.e_phentsize),
                        &ph, sizeof(ph)) != 0)
                break;
            phdrs[phnum].p_type = ph.p_type;
            phdrs[phnum].p_offset = ph.p_offset;
            phdrs[phnum].p_vaddr = ph.p_vaddr;
            phdrs[phnum].p_filesz = ph.p_filesz;
            phnum++;

            if (ph.p_type == PT_INTERP)
                out->has_interp = 1;
            if (ph.p_type == PT_DYNAMIC) {
                has_dynamic_segment = 1;
                dyn_off = ph.p_offset;
                dyn_size = ph.p_filesz;
            }
        }

        if (has_dynamic_segment) {
            out->has_dynamic = 1;
            parse_dynamic64(f, dyn_off, dyn_size, phdrs, phnum, out);
        }
    } else if (e_ident[EI_CLASS] == ELFCLASS32) {
        Elf32_Ehdr ehdr;
        if (read_at(f, 0, &ehdr, sizeof(ehdr)) != 0) {
            fclose(f);
            return ELF_PARSE_UNSUPPORTED;
        }
        out->elf_class = 32;
        out->e_type = ehdr.e_type;
        out->e_machine = ehdr.e_machine;

        int n = ehdr.e_phnum;
        if (n > BLDD_MAX_PHDRS)
            n = BLDD_MAX_PHDRS;
        for (int i = 0; i < n; i++) {
            Elf32_Phdr ph;
            if (read_at(f, (long)(ehdr.e_phoff + (uint64_t)i * ehdr.e_phentsize),
                        &ph, sizeof(ph)) != 0)
                break;
            phdrs[phnum].p_type = ph.p_type;
            phdrs[phnum].p_offset = ph.p_offset;
            phdrs[phnum].p_vaddr = ph.p_vaddr;
            phdrs[phnum].p_filesz = ph.p_filesz;
            phnum++;

            if (ph.p_type == PT_INTERP)
                out->has_interp = 1;
            if (ph.p_type == PT_DYNAMIC) {
                has_dynamic_segment = 1;
                dyn_off = ph.p_offset;
                dyn_size = ph.p_filesz;
            }
        }

        if (has_dynamic_segment) {
            out->has_dynamic = 1;
            parse_dynamic32(f, dyn_off, dyn_size, phdrs, phnum, out);
        }
    } else {
        fclose(f);
        return ELF_PARSE_UNSUPPORTED;
    }

    fclose(f);
    return ELF_PARSE_OK;
}

int elf_is_executable(const elf_info_t *info)
{
    /* Классический не-PIE исполняемый файл */
    if (info->e_type == ET_EXEC)
        return 1;
    /* PIE-исполняемый файл: ET_DYN + PT_INTERP.
       ET_DYN без PT_INTERP -- это разделяемая библиотека (.so), а не программа. */
    if (info->e_type == ET_DYN && info->has_interp)
        return 1;
    return 0;
}

const char *elf_machine_name(uint16_t e_machine)
{
    switch (e_machine) {
        case EM_386:      return "x86 (32-бит)";
        case EM_X86_64:   return "x86-64";
        case EM_ARM:      return "ARM (32-бит)";
        case EM_AARCH64:  return "AArch64 (ARM 64-бит)";
        default: {
            static char buf[32];
            snprintf(buf, sizeof(buf), "Неизвестно (%u)", (unsigned)e_machine);
            return buf;
        }
    }
}

const char *elf_type_name(uint16_t e_type)
{
    switch (e_type) {
        case ET_EXEC: return "EXEC (статически размещаемый)";
        case ET_DYN:  return "DYN (PIE / разделяемый объект)";
        case ET_REL:  return "REL (объектный файл)";
        case ET_CORE: return "CORE (дамп памяти)";
        default:      return "неизвестный";
    }
}

void elf_lib_basename_no_version(const char *name, char *out, size_t out_size)
{
    const char *so = strstr(name, ".so");
    size_t len;
    if (so != NULL) {
        len = (size_t)(so - name) + 3; /* включая ".so" */
    } else {
        len = strlen(name);
    }
    if (len >= out_size)
        len = out_size - 1;
    memcpy(out, name, len);
    out[len] = '\0';
}

'@

Set-Content -Path "src/scanner.c" -Value @'
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

'@

Set-Content -Path "src/report.c" -Value @'
#include "report.h"

#include <stdio.h>
#include <string.h>

/* Экранирование спецсимволов HTML в строке */
static void html_escape(const char *in, char *out, size_t out_size)
{
    size_t j = 0;
    for (size_t i = 0; in[i] != '\0' && j + 6 < out_size; i++) {
        switch (in[i]) {
            case '&': j += (size_t)snprintf(out + j, out_size - j, "&amp;"); break;
            case '<': j += (size_t)snprintf(out + j, out_size - j, "&lt;"); break;
            case '>': j += (size_t)snprintf(out + j, out_size - j, "&gt;"); break;
            case '"': j += (size_t)snprintf(out + j, out_size - j, "&quot;"); break;
            default:  out[j++] = in[i]; break;
        }
    }
    out[j] = '\0';
}

/* Экранирование спецсимволов JSON в строке */
static void json_escape(const char *in, char *out, size_t out_size)
{
    size_t j = 0;
    for (size_t i = 0; in[i] != '\0' && j + 2 < out_size; i++) {
        unsigned char c = (unsigned char)in[i];
        if (c == '"' || c == '\\') {
            if (j + 2 >= out_size) break;
            out[j++] = '\\';
            out[j++] = (char)c;
        } else if (c == '\n') {
            if (j + 2 >= out_size) break;
            out[j++] = '\\'; out[j++] = 'n';
        } else {
            out[j++] = (char)c;
        }
    }
    out[j] = '\0';
}

int report_write_txt(const report_data_t *data, const char *out_path)
{
    FILE *f = fopen(out_path, "w");
    if (!f) return -1;

    fprintf(f, "=== Отчёт bldd (обратный поиск зависимостей ELF) ===\n\n");
    fprintf(f, "Дата генерации:     %s\n", data->generated_at);
    fprintf(f, "Каталог сканирования: %s\n", data->scan_dir);
    fprintf(f, "Найдено исполняемых файлов: %d (в т.ч. статических: %d)\n",
            data->total_scanned, data->total_static);
    fprintf(f, "Пропущено файлов (нет доступа/ошибка чтения): %d\n\n", data->skipped_count);

    for (int i = 0; i < data->lib_count; i++) {
        const report_lib_result_t *lib = &data->libs[i];
        fprintf(f, "--- Искомая библиотека: %s ---\n", lib->lib_name);
        if (lib->resolved) {
            fprintf(f, "Найдена на диске: %s (архитектура: %s)\n",
                    lib->resolved_path, lib->resolved_arch);
        } else {
            fprintf(f, "Файл библиотеки не найден в указанных путях поиска "
                       "(совпадения по архитектуре не проверялись).\n");
        }
        fprintf(f, "Используют её файлов: %d\n", lib->row_count);
        for (int r = 0; r < lib->row_count; r++) {
            fprintf(f, "  [%2d] %-50s архитектура=%-14s всего зависимостей=%d\n",
                    r + 1, lib->rows[r].path, lib->rows[r].arch, lib->rows[r].total_needed);
        }
        fprintf(f, "\n");
    }

    fprintf(f, "=== Итоговая таблица: исполняемые файлы по убыванию числа "
               "использованных искомых библиотек ===\n");
    for (int i = 0; i < data->summary_count; i++) {
        fprintf(f, "  [%2d] %-50s исп. библиотек=%d  архитектура=%s\n",
                i + 1, data->summary_rows[i].path,
                data->summary_rows[i].matched_libs, data->summary_rows[i].arch);
    }

    fclose(f);
    return 0;
}

int report_write_html(const report_data_t *data, const char *out_path)
{
    FILE *f = fopen(out_path, "w");
    if (!f) return -1;

    char esc[PATH_MAX + 64];

    fprintf(f, "<!DOCTYPE html>\n<html lang=\"ru\"><head><meta charset=\"utf-8\">"
               "<title>Отчёт bldd</title>\n<style>"
               "body{font-family:sans-serif;margin:2em;}"
               "table{border-collapse:collapse;width:100%%;margin-bottom:2em;}"
               "th,td{border:1px solid #ccc;padding:4px 8px;text-align:left;}"
               "th{background:#eee;}"
               "h2{margin-top:2em;}"
               "</style></head><body>\n");

    fprintf(f, "<h1>Отчёт bldd (обратный поиск зависимостей ELF)</h1>\n");
    fprintf(f, "<p><b>Дата генерации:</b> %s<br>\n", data->generated_at);
    html_escape(data->scan_dir, esc, sizeof(esc));
    fprintf(f, "<b>Каталог сканирования:</b> %s<br>\n", esc);
    fprintf(f, "<b>Найдено исполняемых файлов:</b> %d (статических: %d)<br>\n",
            data->total_scanned, data->total_static);
    fprintf(f, "<b>Пропущено файлов:</b> %d</p>\n", data->skipped_count);

    for (int i = 0; i < data->lib_count; i++) {
        const report_lib_result_t *lib = &data->libs[i];
        html_escape(lib->lib_name, esc, sizeof(esc));
        fprintf(f, "<h2>Библиотека: %s</h2>\n", esc);
        if (lib->resolved) {
            html_escape(lib->resolved_path, esc, sizeof(esc));
            fprintf(f, "<p>Найдена на диске: <code>%s</code> (архитектура: %s)</p>\n",
                    esc, lib->resolved_arch);
        } else {
            fprintf(f, "<p><i>Файл библиотеки не найден в путях поиска.</i></p>\n");
        }
        fprintf(f, "<table><tr><th>#</th><th>Путь к файлу</th>"
                   "<th>Архитектура</th><th>Всего зависимостей</th></tr>\n");
        for (int r = 0; r < lib->row_count; r++) {
            html_escape(lib->rows[r].path, esc, sizeof(esc));
            fprintf(f, "<tr><td>%d</td><td>%s</td><td>%s</td><td>%d</td></tr>\n",
                    r + 1, esc, lib->rows[r].arch, lib->rows[r].total_needed);
        }
        fprintf(f, "</table>\n");
    }

    fprintf(f, "<h2>Итоговая таблица по всем искомым библиотекам</h2>\n");
    fprintf(f, "<table><tr><th>#</th><th>Путь к файлу</th>"
               "<th>Архитектура</th><th>Использовано искомых библиотек</th></tr>\n");
    for (int i = 0; i < data->summary_count; i++) {
        html_escape(data->summary_rows[i].path, esc, sizeof(esc));
        fprintf(f, "<tr><td>%d</td><td>%s</td><td>%s</td><td>%d</td></tr>\n",
                i + 1, esc, data->summary_rows[i].arch, data->summary_rows[i].matched_libs);
    }
    fprintf(f, "</table>\n</body></html>\n");

    fclose(f);
    return 0;
}

int report_write_json(const report_data_t *data, const char *out_path)
{
    FILE *f = fopen(out_path, "w");
    if (!f) return -1;

    char esc[PATH_MAX + 64];

    fprintf(f, "{\n");
    fprintf(f, "  \"generated_at\": \"%s\",\n", data->generated_at);
    json_escape(data->scan_dir, esc, sizeof(esc));
    fprintf(f, "  \"scan_dir\": \"%s\",\n", esc);
    fprintf(f, "  \"total_scanned\": %d,\n", data->total_scanned);
    fprintf(f, "  \"total_static\": %d,\n", data->total_static);
    fprintf(f, "  \"skipped_count\": %d,\n", data->skipped_count);

    fprintf(f, "  \"libraries\": [\n");
    for (int i = 0; i < data->lib_count; i++) {
        const report_lib_result_t *lib = &data->libs[i];
        json_escape(lib->lib_name, esc, sizeof(esc));
        fprintf(f, "    {\n      \"name\": \"%s\",\n", esc);
        fprintf(f, "      \"resolved\": %s,\n", lib->resolved ? "true" : "false");
        if (lib->resolved) {
            json_escape(lib->resolved_path, esc, sizeof(esc));
            fprintf(f, "      \"resolved_path\": \"%s\",\n", esc);
            fprintf(f, "      \"resolved_arch\": \"%s\",\n", lib->resolved_arch);
        }
        fprintf(f, "      \"used_by\": [\n");
        for (int r = 0; r < lib->row_count; r++) {
            json_escape(lib->rows[r].path, esc, sizeof(esc));
            fprintf(f, "        {\"path\": \"%s\", \"arch\": \"%s\", \"total_needed\": %d}%s\n",
                    esc, lib->rows[r].arch, lib->rows[r].total_needed,
                    (r + 1 < lib->row_count) ? "," : "");
        }
        fprintf(f, "      ]\n    }%s\n", (i + 1 < data->lib_count) ? "," : "");
    }
    fprintf(f, "  ],\n");

    fprintf(f, "  \"summary\": [\n");
    for (int i = 0; i < data->summary_count; i++) {
        json_escape(data->summary_rows[i].path, esc, sizeof(esc));
        fprintf(f, "    {\"path\": \"%s\", \"arch\": \"%s\", \"matched_libs\": %d}%s\n",
                esc, data->summary_rows[i].arch, data->summary_rows[i].matched_libs,
                (i + 1 < data->summary_count) ? "," : "");
    }
    fprintf(f, "  ]\n}\n");

    fclose(f);
    return 0;
}

'@

Set-Content -Path "src/main.c" -Value @'
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

'@