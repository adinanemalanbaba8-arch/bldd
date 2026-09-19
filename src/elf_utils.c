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

