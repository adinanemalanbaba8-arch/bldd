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

