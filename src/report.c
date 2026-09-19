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

