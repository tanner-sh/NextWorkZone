#pragma once
#include <libxml/HTMLparser.h>
#include <libxml/tree.h>

// Swift 严格并发不能直接读取 libxml2 的全局分配器函数指针。
static inline void nwz_xml_free(void *pointer) { xmlFree(pointer); }
