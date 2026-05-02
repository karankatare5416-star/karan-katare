#!/bin/bash
# =============================================================================
# Hybrid Inventory Manager — Self-Extracting Project Script
# Run: bash hybrid_inventory_manager.sh
# This will create the full project in ./HybridInventoryManager/
# =============================================================================

set -e
PROJECT="HybridInventoryManager"
mkdir -p "$PROJECT/include" "$PROJECT/src"
cd "$PROJECT"

echo ">>> Creating project structure..."

# =============================================================================
# FILE 1: include/inventory.h
# =============================================================================
cat > include/inventory.h << 'HEADER_EOF'
/*
 * inventory.h — C Backend Interface
 * Pure C header. Safe to include from both C and C++ translation units.
 *
 * Architecture:
 *   - Item is the core data structure stored in binary format.
 *   - All backend functions use C linkage (extern "C" when compiled as C++).
 *   - Return 1 on success, 0 on failure (except list_items → count).
 */

#ifndef INVENTORY_H
#define INVENTORY_H

#ifdef __cplusplus
extern "C" {
#endif

#define INVENTORY_FILE  "inventory.dat"
#define MAX_NAME_LEN    40
#define LIST_MAX        1024

/* ─── Core Data Structure ─────────────────────────────────────────────────── */

typedef struct {
    int   id;                    /* Unique positive identifier          */
    char  name[MAX_NAME_LEN];    /* Item name (null-terminated)         */
    int   quantity;              /* Stock count (>= 0)                  */
    float price;                 /* Unit price  (>= 0.0)                */
    int   is_deleted;            /* Soft-delete flag: 1=deleted, 0=live */
} Item;

/* ─── C Backend API ───────────────────────────────────────────────────────── */

/*
 * add_item — Appends a new item to the binary file.
 * Rejects: duplicate IDs, invalid fields.
 * Returns 1 on success, 0 on failure.
 */
int add_item(const Item* item);

/*
 * get_item — Reads a single live item by ID into *out.
 * Returns 1 if found and not deleted, 0 otherwise.
 */
int get_item(int id, Item* out);

/*
 * update_item — Overwrites the record at the position of 'id' in-place.
 * Returns 1 on success, 0 if not found or deleted.
 */
int update_item(int id, const Item* updated);

/*
 * delete_item — Sets is_deleted = 1 for the record with given id.
 * Returns 1 on success, 0 if not found or already deleted.
 */
int delete_item(int id);

/*
 * list_items — Fills buffer[] with all live (non-deleted) items.
 * max_items: capacity of buffer[].
 * Returns the number of live items written to buffer (0..max_items).
 */
int list_items(Item* buffer, int max_items);

#ifdef __cplusplus
}
#endif

#endif /* INVENTORY_H */
HEADER_EOF

echo "    [OK] include/inventory.h"

# =============================================================================
# FILE 2: src/inventory.c
# =============================================================================
cat > src/inventory.c << 'C_EOF'
/*
 * inventory.c — C Backend Implementation
 *
 * Binary file layout:
 *   [Item][Item][Item]...
 *   Each record is sizeof(Item) bytes, stored sequentially.
 *   Soft-deleted records remain in place (is_deleted = 1).
 *
 * Strategy:
 *   - add_item    → scan for duplicate, then append at EOF.
 *   - get_item    → linear scan, match id + !is_deleted.
 *   - update_item → find offset, fseek, overwrite in place.
 *   - delete_item → find offset, flip is_deleted, write back.
 *   - list_items  → stream all records, collect live ones.
 *
 * All functions open/close the file independently so the C++ layer
 * need not manage any file handles.
 */

#include "inventory.h"

#include <stdio.h>
#include <string.h>

/* ─── Internal helpers ────────────────────────────────────────────────────── */

/*
 * open_file — Thin wrapper around fopen with a human-readable mode string.
 * Returns NULL on failure.
 */
static FILE* open_file(const char* mode)
{
    return fopen(INVENTORY_FILE, mode);
}

/*
 * find_record — Scans the open file for a record whose id matches 'target_id'.
 * On success, *offset holds the byte position of that record and *out holds
 * the record itself; returns 1.
 * Returns 0 if not found or on I/O error.
 *
 * Note: Does NOT skip deleted records — callers decide what to do with them.
 */
static int find_record(FILE* fp, int target_id, long* offset, Item* out)
{
    Item tmp;
    rewind(fp);

    while (fread(&tmp, sizeof(Item), 1, fp) == 1) {
        if (tmp.id == target_id) {
            *offset = ftell(fp) - (long)sizeof(Item);
            *out    = tmp;
            return 1;
        }
    }
    return 0;
}

/* ─── Public API ──────────────────────────────────────────────────────────── */

int add_item(const Item* item)
{
    FILE* fp;
    Item  tmp;
    long  dummy_offset;

    /* ── Validate fields ── */
    if (!item)                      return 0;
    if (item->id <= 0)              return 0;
    if (item->quantity < 0)         return 0;
    if (item->price < 0.0f)        return 0;
    if (item->name[0] == '\0')      return 0;

    /*
     * Open in "r+b" (read+write, no truncate) to check for duplicates.
     * If the file does not yet exist, that's fine — we create it below.
     */
    fp = open_file("r+b");
    if (fp) {
        /* Reject duplicate IDs — deleted or alive */
        if (find_record(fp, item->id, &dummy_offset, &tmp)) {
            fclose(fp);
            return 0; /* Duplicate */
        }
        /* Append at end of file */
        fseek(fp, 0, SEEK_END);
        if (fwrite(item, sizeof(Item), 1, fp) != 1) {
            fclose(fp);
            return 0;
        }
        fclose(fp);
        return 1;
    }

    /* File doesn't exist yet — create it */
    fp = open_file("wb");
    if (!fp) return 0;

    if (fwrite(item, sizeof(Item), 1, fp) != 1) {
        fclose(fp);
        return 0;
    }
    fclose(fp);
    return 1;
}

int get_item(int id, Item* out)
{
    FILE* fp;
    Item  tmp;
    long  offset;

    if (!out || id <= 0) return 0;

    fp = open_file("rb");
    if (!fp) return 0;

    if (!find_record(fp, id, &offset, &tmp)) {
        fclose(fp);
        return 0; /* Not found */
    }
    fclose(fp);

    if (tmp.is_deleted) return 0; /* Soft-deleted */

    *out = tmp;
    return 1;
}

int update_item(int id, const Item* updated)
{
    FILE* fp;
    Item  existing;
    long  offset;

    if (!updated || id <= 0)    return 0;
    if (updated->quantity < 0)  return 0;
    if (updated->price < 0.0f) return 0;
    if (updated->name[0] == '\0') return 0;

    fp = open_file("r+b");
    if (!fp) return 0;

    if (!find_record(fp, id, &offset, &existing)) {
        fclose(fp);
        return 0;
    }
    if (existing.is_deleted) {
        fclose(fp);
        return 0;
    }

    /* Seek to the record's start position and overwrite */
    fseek(fp, offset, SEEK_SET);
    if (fwrite(updated, sizeof(Item), 1, fp) != 1) {
        fclose(fp);
        return 0;
    }
    fclose(fp);
    return 1;
}

int delete_item(int id)
{
    FILE* fp;
    Item  existing;
    long  offset;

    if (id <= 0) return 0;

    fp = open_file("r+b");
    if (!fp) return 0;

    if (!find_record(fp, id, &offset, &existing)) {
        fclose(fp);
        return 0;
    }
    if (existing.is_deleted) {
        fclose(fp);
        return 0; /* Already deleted */
    }

    existing.is_deleted = 1;

    fseek(fp, offset, SEEK_SET);
    if (fwrite(&existing, sizeof(Item), 1, fp) != 1) {
        fclose(fp);
        return 0;
    }
    fclose(fp);
    return 1;
}

int list_items(Item* buffer, int max_items)
{
    FILE* fp;
    Item  tmp;
    int   count = 0;

    if (!buffer || max_items <= 0) return 0;

    fp = open_file("rb");
    if (!fp) return 0; /* No file yet — empty inventory */

    while (count < max_items && fread(&tmp, sizeof(Item), 1, fp) == 1) {
        if (!tmp.is_deleted) {
            buffer[count++] = tmp;
        }
    }
    fclose(fp);
    return count;
}
C_EOF

echo "    [OK] src/inventory.c"

# =============================================================================
# FILE 3: src/InventoryManager.cpp
# =============================================================================
cat > src/InventoryManager.cpp << 'CPP_EOF'
/*
 * InventoryManager.cpp — C++ Frontend Layer
 *
 * Responsibilities:
 *   - Wrap the C backend API behind a clean C++ interface.
 *   - Own all user interaction (menus, prompts, formatted output).
 *   - Validate every user input before forwarding to C layer.
 *   - Use std::vector<Item> for in-memory list operations.
 *   - Use std::sort for ordering results.
 *
 * Design notes:
 *   - No raw I/O in the C layer — all console work lives here.
 *   - All input functions loop until valid data is provided,
 *     preventing crashes from bad keyboard input.
 */

#include "InventoryManager.h"
#include "inventory.h"

#include <algorithm>
#include <cctype>
#include <cstring>
#include <iomanip>
#include <iostream>
#include <limits>
#include <sstream>
#include <string>
#include <vector>

/* ─── ANSI colour helpers (gracefully degrade on Windows cmd) ──────────────── */
#define COL_RESET   "\033[0m"
#define COL_BOLD    "\033[1m"
#define COL_CYAN    "\033[36m"
#define COL_GREEN   "\033[32m"
#define COL_YELLOW  "\033[33m"
#define COL_RED     "\033[31m"
#define COL_BLUE    "\033[34m"
#define COL_MAGENTA "\033[35m"

/* ─── Private helpers (file-scope) ─────────────────────────────────────────── */

namespace {

/* Flush the input stream after a read to discard trailing newlines / garbage. */
void flush_cin()
{
    std::cin.clear();
    std::cin.ignore(std::numeric_limits<std::streamsize>::max(), '\n');
}

/* Read a positive integer from stdin; loop on bad input. */
int prompt_positive_int(const std::string& label)
{
    int val;
    while (true) {
        std::cout << COL_CYAN << label << COL_RESET;
        if (std::cin >> val && val > 0) {
            flush_cin();
            return val;
        }
        flush_cin();
        std::cout << COL_RED << "  [!] Must be a positive integer. Try again.\n"
                  << COL_RESET;
    }
}

/* Read a non-negative integer from stdin; loop on bad input. */
int prompt_nonneg_int(const std::string& label)
{
    int val;
    while (true) {
        std::cout << COL_CYAN << label << COL_RESET;
        if (std::cin >> val && val >= 0) {
            flush_cin();
            return val;
        }
        flush_cin();
        std::cout << COL_RED << "  [!] Must be >= 0. Try again.\n" << COL_RESET;
    }
}

/* Read a non-negative float from stdin; loop on bad input. */
float prompt_nonneg_float(const std::string& label)
{
    float val;
    while (true) {
        std::cout << COL_CYAN << label << COL_RESET;
        if (std::cin >> val && val >= 0.0f) {
            flush_cin();
            return val;
        }
        flush_cin();
        std::cout << COL_RED << "  [!] Must be >= 0.0. Try again.\n" << COL_RESET;
    }
}

/* Read a non-empty string from stdin; loop on blank input. */
std::string prompt_nonempty_string(const std::string& label)
{
    std::string val;
    while (true) {
        std::cout << COL_CYAN << label << COL_RESET;
        std::getline(std::cin, val);

        /* Trim leading/trailing whitespace */
        size_t start = val.find_first_not_of(" \t\r\n");
        size_t end   = val.find_last_not_of(" \t\r\n");
        if (start != std::string::npos) {
            val = val.substr(start, end - start + 1);
        } else {
            val.clear();
        }

        if (!val.empty()) return val;
        std::cout << COL_RED << "  [!] Name cannot be empty. Try again.\n"
                  << COL_RESET;
    }
}

/* Print a horizontal rule */
void rule(char ch = '-', int width = 72)
{
    std::cout << COL_BLUE;
    for (int i = 0; i < width; ++i) std::cout << ch;
    std::cout << COL_RESET << '\n';
}

/* Print the table header for item listings */
void print_table_header()
{
    rule('=');
    std::cout << COL_BOLD
              << std::left
              << std::setw(6)  << "ID"
              << std::setw(22) << "Name"
              << std::setw(10) << "Quantity"
              << std::setw(12) << "Price (USD)"
              << COL_RESET << '\n';
    rule('-');
}

/* Print a single Item row */
void print_item_row(const Item& it)
{
    std::cout << std::left
              << std::setw(6)  << it.id
              << std::setw(22) << it.name
              << std::setw(10) << it.quantity
              << "$" << std::fixed << std::setprecision(2)
              << std::setw(11) << it.price
              << '\n';
}

} /* anonymous namespace */

/* ─── InventoryManager implementation ──────────────────────────────────────── */

InventoryManager::InventoryManager()
{
    /* Nothing to initialise — the C backend manages the file. */
}

InventoryManager::~InventoryManager()
{
    /* Nothing to clean up — no heap allocations owned here. */
}

/* ── run() ─── Main event loop ─────────────────────────────────────────────── */

void InventoryManager::run()
{
    print_banner();

    while (true) {
        print_menu();

        int choice = 0;
        std::cout << COL_BOLD << "Enter choice: " << COL_RESET;

        if (!(std::cin >> choice)) {
            flush_cin();
            std::cout << COL_RED << "  [!] Invalid input.\n" << COL_RESET;
            continue;
        }
        flush_cin();

        switch (choice) {
            case 1: handle_add();    break;
            case 2: handle_view();   break;
            case 3: handle_update(); break;
            case 4: handle_delete(); break;
            case 5: handle_list();   break;
            case 6:
                std::cout << COL_GREEN
                          << "\n  Goodbye! Data persisted to '"
                          << INVENTORY_FILE << "'.\n\n"
                          << COL_RESET;
                return;
            default:
                std::cout << COL_RED
                          << "  [!] Unknown option. Please choose 1–6.\n"
                          << COL_RESET;
        }
    }
}

/* ── UI helpers ─────────────────────────────────────────────────────────────── */

void InventoryManager::print_banner() const
{
    std::cout << '\n';
    rule('=');
    std::cout << COL_BOLD << COL_MAGENTA
              << "        HYBRID INVENTORY MANAGER  v1.0\n"
              << "        C Backend  +  C++ Frontend\n"
              << COL_RESET;
    rule('=');
    std::cout << "  Data file: " << COL_YELLOW << INVENTORY_FILE
              << COL_RESET << "\n\n";
}

void InventoryManager::print_menu() const
{
    std::cout << '\n'
              << COL_BOLD << "  MENU\n" << COL_RESET;
    rule('-', 30);
    std::cout << "  " << COL_YELLOW << "1." << COL_RESET << " Add Item\n"
              << "  " << COL_YELLOW << "2." << COL_RESET << " View Item\n"
              << "  " << COL_YELLOW << "3." << COL_RESET << " Update Item\n"
              << "  " << COL_YELLOW << "4." << COL_RESET << " Delete Item\n"
              << "  " << COL_YELLOW << "5." << COL_RESET << " List All Items\n"
              << "  " << COL_YELLOW << "6." << COL_RESET << " Exit\n";
    rule('-', 30);
}

/* ── handle_add ─────────────────────────────────────────────────────────────── */

void InventoryManager::handle_add()
{
    std::cout << '\n' << COL_BOLD << "── Add New Item ──\n" << COL_RESET;

    Item it;
    memset(&it, 0, sizeof(Item));

    it.id        = prompt_positive_int("  ID       : ");
    std::string nm = prompt_nonempty_string("  Name     : ");
    strncpy(it.name, nm.c_str(), MAX_NAME_LEN - 1);
    it.name[MAX_NAME_LEN - 1] = '\0';
    it.quantity  = prompt_nonneg_int  ("  Quantity : ");
    it.price     = prompt_nonneg_float("  Price    : ");
    it.is_deleted = 0;

    if (add_item(&it)) {
        std::cout << COL_GREEN << "  [✓] Item #" << it.id
                  << " added successfully.\n" << COL_RESET;
    } else {
        std::cout << COL_RED
                  << "  [✗] Failed to add item. "
                     "Duplicate ID or invalid fields.\n"
                  << COL_RESET;
    }
}

/* ── handle_view ────────────────────────────────────────────────────────────── */

void InventoryManager::handle_view()
{
    std::cout << '\n' << COL_BOLD << "── View Item ──\n" << COL_RESET;

    int id = prompt_positive_int("  Enter ID: ");
    Item it;

    if (get_item(id, &it)) {
        print_table_header();
        print_item_row(it);
        rule('-');
    } else {
        std::cout << COL_RED
                  << "  [✗] Item #" << id << " not found or deleted.\n"
                  << COL_RESET;
    }
}

/* ── handle_update ──────────────────────────────────────────────────────────── */

void InventoryManager::handle_update()
{
    std::cout << '\n' << COL_BOLD << "── Update Item ──\n" << COL_RESET;

    int id = prompt_positive_int("  Enter ID to update: ");

    /* Verify the item exists before asking for new values */
    Item existing;
    if (!get_item(id, &existing)) {
        std::cout << COL_RED
                  << "  [✗] Item #" << id << " not found or deleted.\n"
                  << COL_RESET;
        return;
    }

    std::cout << COL_YELLOW
              << "  Current: [" << existing.name
              << "] qty=" << existing.quantity
              << " price=$" << std::fixed << std::setprecision(2)
              << existing.price << "\n"
              << COL_RESET;
    std::cout << "  (Enter new values — press Enter to keep existing)\n";

    /* New name — allow blank to keep old */
    std::cout << COL_CYAN << "  New Name [" << existing.name << "]: "
              << COL_RESET;
    std::string nm;
    std::getline(std::cin, nm);
    if (nm.empty()) {
        /* keep existing name */
    } else {
        strncpy(existing.name, nm.c_str(), MAX_NAME_LEN - 1);
        existing.name[MAX_NAME_LEN - 1] = '\0';
    }

    existing.quantity  = prompt_nonneg_int  ("  New Quantity : ");
    existing.price     = prompt_nonneg_float("  New Price    : ");
    existing.id        = id; /* Preserve original ID */
    existing.is_deleted = 0;

    if (update_item(id, &existing)) {
        std::cout << COL_GREEN << "  [✓] Item #" << id
                  << " updated.\n" << COL_RESET;
    } else {
        std::cout << COL_RED << "  [✗] Update failed.\n" << COL_RESET;
    }
}

/* ── handle_delete ──────────────────────────────────────────────────────────── */

void InventoryManager::handle_delete()
{
    std::cout << '\n' << COL_BOLD << "── Delete Item ──\n" << COL_RESET;

    int id = prompt_positive_int("  Enter ID to delete: ");

    /* Confirm */
    std::cout << COL_YELLOW << "  Are you sure? (y/N): " << COL_RESET;
    std::string confirm;
    std::getline(std::cin, confirm);
    if (confirm != "y" && confirm != "Y") {
        std::cout << "  Cancelled.\n";
        return;
    }

    if (delete_item(id)) {
        std::cout << COL_GREEN << "  [✓] Item #" << id
                  << " deleted (soft).\n" << COL_RESET;
    } else {
        std::cout << COL_RED
                  << "  [✗] Item #" << id << " not found or already deleted.\n"
                  << COL_RESET;
    }
}

/* ── handle_list ────────────────────────────────────────────────────────────── */

void InventoryManager::handle_list()
{
    std::cout << '\n' << COL_BOLD << "── List All Items ──\n" << COL_RESET;

    /* Pull all live items into a C-array, then move into std::vector */
    Item raw_buf[LIST_MAX];
    int  count = list_items(raw_buf, LIST_MAX);

    if (count == 0) {
        std::cout << COL_YELLOW << "  No items in inventory.\n" << COL_RESET;
        return;
    }

    /* Copy into std::vector for STL operations */
    std::vector<Item> items(raw_buf, raw_buf + count);

    /* ── Ask sort preference ── */
    std::cout << "  Sort by: " << COL_YELLOW << "1" << COL_RESET
              << "=ID  " << COL_YELLOW << "2" << COL_RESET
              << "=Name  " << COL_YELLOW << "3" << COL_RESET
              << "=Price  [default=ID]: ";

    int sort_choice = 1;
    std::string sc_str;
    std::getline(std::cin, sc_str);
    if (!sc_str.empty()) sort_choice = sc_str[0] - '0';

    switch (sort_choice) {
        case 2:
            std::sort(items.begin(), items.end(),
                [](const Item& a, const Item& b) {
                    return std::string(a.name) < std::string(b.name);
                });
            break;
        case 3:
            std::sort(items.begin(), items.end(),
                [](const Item& a, const Item& b) {
                    return a.price < b.price;
                });
            break;
        default: /* 1 or invalid → sort by id */
            std::sort(items.begin(), items.end(),
                [](const Item& a, const Item& b) {
                    return a.id < b.id;
                });
            break;
    }

    /* ── Render table ── */
    print_table_header();
    for (const Item& it : items) {
        print_item_row(it);
    }
    rule('=');

    /* ── Summary statistics ── */
    double total_value = 0.0;
    int    total_qty   = 0;
    for (const Item& it : items) {
        total_value += static_cast<double>(it.price) * it.quantity;
        total_qty   += it.quantity;
    }

    std::cout << COL_BOLD
              << "  Total items listed : " << count       << '\n'
              << "  Total units in stock: " << total_qty  << '\n'
              << "  Total inventory value: $"
              << std::fixed << std::setprecision(2) << total_value << '\n'
              << COL_RESET;
}
CPP_EOF

echo "    [OK] src/InventoryManager.cpp"

# =============================================================================
# FILE 4: src/InventoryManager.h (needed by both cpp files)
# =============================================================================
cat > include/InventoryManager.h << 'IMHDR_EOF'
/*
 * InventoryManager.h — C++ Frontend Class Declaration
 *
 * This class owns the interactive console UI and delegates all
 * persistence operations to the C backend API (inventory.h).
 */

#ifndef INVENTORY_MANAGER_H
#define INVENTORY_MANAGER_H

/* ─── C++ class — do NOT include in C translation units ─────────────────────── */

class InventoryManager {
public:
    InventoryManager();
    ~InventoryManager();

    /* Entry point: runs the interactive menu loop until user exits. */
    void run();

private:
    /* UI rendering */
    void print_banner() const;
    void print_menu()   const;

    /* Menu action handlers */
    void handle_add();
    void handle_view();
    void handle_update();
    void handle_delete();
    void handle_list();
};

#endif /* INVENTORY_MANAGER_H */
IMHDR_EOF

echo "    [OK] include/InventoryManager.h"

# =============================================================================
# FILE 5: src/main.cpp
# =============================================================================
cat > src/main.cpp << 'MAIN_EOF'
/*
 * main.cpp — Application Entry Point
 *
 * Constructs the InventoryManager (C++ frontend) on the stack and
 * starts the interactive session. All persistence is handled by
 * the C backend transparently.
 */

#include "InventoryManager.h"

int main()
{
    InventoryManager mgr;
    mgr.run();
    return 0;
}
MAIN_EOF

echo "    [OK] src/main.cpp"

# =============================================================================
# FILE 6: Makefile
# =============================================================================
cat > Makefile << 'MK_EOF'
# =============================================================================
# Makefile — Hybrid Inventory Manager
#
# Toolchain:
#   gcc   → compiles the C backend (src/inventory.c)
#   g++   → compiles the C++ frontend and links the final binary
#
# Flags:
#   -Wall -Wextra    : maximal warnings
#   -std=c11         : C11 for the backend
#   -std=c++17       : C++17 for the frontend (lambdas, structured bindings)
#   -Iinclude        : shared include path for both compilers
# =============================================================================

CC      := gcc
CXX     := g++
CFLAGS  := -Wall -Wextra -std=c11   -Iinclude
CXXFLAGS:= -Wall -Wextra -std=c++17 -Iinclude
TARGET  := inventory_mgr

# Object files
C_OBJ   := build/inventory.o
CXX_OBJ := build/InventoryManager.o build/main.o

ALL_OBJ := $(C_OBJ) $(CXX_OBJ)

# ── Default target ────────────────────────────────────────────────────────── #
.PHONY: all clean run

all: build $(TARGET)

# Ensure build directory exists
build:
	mkdir -p build

# ── Link: use g++ as the linker so the C++ runtime is included ────────────── #
$(TARGET): $(ALL_OBJ)
	$(CXX) $(CXXFLAGS) -o $@ $^
	@echo ""
	@echo "  Build successful → ./$(TARGET)"
	@echo ""

# ── Compile C backend ─────────────────────────────────────────────────────── #
build/inventory.o: src/inventory.c include/inventory.h
	$(CC) $(CFLAGS) -c $< -o $@

# ── Compile C++ frontend ──────────────────────────────────────────────────── #
build/InventoryManager.o: src/InventoryManager.cpp include/InventoryManager.h include/inventory.h
	$(CXX) $(CXXFLAGS) -c $< -o $@

build/main.o: src/main.cpp include/InventoryManager.h
	$(CXX) $(CXXFLAGS) -c $< -o $@

# ── Convenience targets ───────────────────────────────────────────────────── #
run: all
	./$(TARGET)

clean:
	rm -rf build $(TARGET) inventory.dat
	@echo "  Cleaned build artifacts."
MK_EOF

echo "    [OK] Makefile"

# =============================================================================
# FILE 7: README.md
# =============================================================================
cat > README.md << 'README_EOF'
# Hybrid Inventory Manager

A production-quality console application demonstrating a **hybrid C/C++ architecture**:

| Layer        | Language | Responsibility                                  |
|-------------|----------|-------------------------------------------------|
| Backend      | C        | Binary file I/O, data structs, CRUD operations  |
| Frontend     | C++      | Console UI, input validation, STL sorting       |

---

## Project Structure

```
HybridInventoryManager/
├── include/
│   ├── inventory.h          # C struct + extern "C" API declarations
│   └── InventoryManager.h   # C++ class declaration
├── src/
│   ├── inventory.c          # C backend implementation
│   ├── InventoryManager.cpp # C++ UI + logic layer
│   └── main.cpp             # Entry point
├── Makefile
└── README.md
```

---

## Build Steps

### Prerequisites

| Tool | Minimum version |
|------|----------------|
| gcc  | 7.x            |
| g++  | 7.x            |
| make | 3.8            |

### Build

```bash
make          # Compiles everything → ./inventory_mgr
make clean    # Remove build artifacts and inventory.dat
make run      # Build and launch immediately
```

---

## Run Instructions

```bash
./inventory_mgr
```

You will see the main menu:

```
  MENU
------------------------------
  1. Add Item
  2. View Item
  3. Update Item
  4. Delete Item
  5. List All Items
  6. Exit
------------------------------
```

Navigate with numbers `1`–`6`. The program loops until you choose **6 (Exit)**.

Data is persisted to `inventory.dat` (binary) in the current directory.  
**Restart the program** and choose **List All Items** to confirm persistence.

---

## 5 Test Cases

### Test 1 — Add Items

```
Menu > 1
  ID       : 101
  Name     : Laptop
  Quantity : 15
  Price    : 999.99
→ [✓] Item #101 added successfully.

Menu > 1
  ID       : 102
  Name     : Wireless Mouse
  Quantity : 50
  Price    : 29.99
→ [✓] Item #102 added successfully.

Menu > 1
  ID       : 103
  Name     : USB-C Hub
  Quantity : 30
  Price    : 49.95
→ [✓] Item #103 added successfully.
```

### Test 2 — Duplicate ID Rejection

```
Menu > 1
  ID       : 101
  Name     : Tablet
  Quantity : 5
  Price    : 499.00
→ [✗] Failed to add item. Duplicate ID or invalid fields.
```

### Test 3 — View Item

```
Menu > 2
  Enter ID: 102
========================================================================
ID    Name                  Quantity  Price (USD)
------------------------------------------------------------------------
102   Wireless Mouse        50        $29.99
========================================================================
```

### Test 4 — Update Item

```
Menu > 3
  Enter ID to update: 103
  Current: [USB-C Hub] qty=30 price=$49.95
  New Name [USB-C Hub]:          ← (blank, keep existing)
  New Quantity : 25
  New Price    : 54.99
→ [✓] Item #103 updated.
```

### Test 5 — Delete + List (Persistence)

```
Menu > 4
  Enter ID to delete: 102
  Are you sure? (y/N): y
→ [✓] Item #102 deleted (soft).

Menu > 5
  Sort by: 1=ID  2=Name  3=Price  [default=ID]: 1
========================================================================
ID    Name                  Quantity  Price (USD)
------------------------------------------------------------------------
101   Laptop                15        $999.99
103   USB-C Hub             25        $54.99
========================================================================
  Total items listed : 2
  Total units in stock: 40
  Total inventory value: $16374.60

Menu > 6
  Goodbye! Data persisted to 'inventory.dat'.

# ── Re-launch ──
./inventory_mgr
Menu > 5
→ Same 2 items appear. Persistence confirmed ✓
```

---

## Architecture Notes

### Why `extern "C"`?

The C backend is compiled by `gcc` using C name mangling.  
The C++ layer is compiled by `g++`, which uses decorated (mangled) names.  
`extern "C"` in `inventory.h` tells the C++ compiler to use C linkage for those symbols, allowing `g++` to correctly call into the `gcc`-compiled object file.

### Binary File Layout

```
[Item 0 — 56 bytes][Item 1 — 56 bytes]...[Item N — 56 bytes]
```

`sizeof(Item) = 4 + 40 + 4 + 4 + 4 = 56 bytes` (may vary slightly by platform padding).

Updates and deletes use `fseek` + `fwrite` for **in-place mutation** — no record is ever physically removed, keeping the file compact and writes O(1).

---

## Error Handling

| Scenario                      | Behaviour                                     |
|-------------------------------|-----------------------------------------------|
| File not found on first run   | Backend creates `inventory.dat` automatically |
| Negative quantity / price     | Rejected before reaching the C layer          |
| Empty name                    | Rejected, user re-prompted                    |
| Duplicate ID                  | Detected via full linear scan, rejected       |
| Non-numeric keyboard input    | `cin` error cleared, user re-prompted         |
| View / delete missing ID      | Informative error message, no crash           |
README_EOF

echo "    [OK] README.md"

cd ..
echo ""
echo "============================================================"
echo "  Project created in: ./$PROJECT/"
echo ""
echo "  To build and run:"
echo "    cd $PROJECT"
echo "    make run"
echo "============================================================"
