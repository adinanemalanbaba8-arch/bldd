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

