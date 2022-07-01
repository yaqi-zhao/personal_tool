/*******************************************************************************
 * Copyright (C) 2022 Intel Corporation
 *
 * SPDX-License-Identifier: MIT
 ******************************************************************************/


#include <fcntl.h>
#include <sys/mman.h>
#include <dlfcn.h>
#include <iostream>

#include "hw_queue.hpp"
#include "hw_configuration_driver.h"
#include "algorithm"
#include "hw_device.hpp"
#include "hw_descriptors_api.h"

using namespace std;

#define QPL_HWSTS_RET(expr, err_code) { if( expr ) { return( err_code ); }}
#define DEC_BASE 10u         /**< @todo */
#define DEC_CHAR_BASE ('0')  /**< @todo */
#define DEC_MAX_INT_BUF 16u  /**< @todo */

static const char *accelerator_configuration_driver_name = "libaccel-config.so.1";

static qpl_desc_t functions_table[] = {
        {NULL, "accfg_new"},
        {NULL, "accfg_device_get_first"},
        {NULL, "accfg_device_get_devname"},
        {NULL, "accfg_device_get_next"},
        {NULL, "accfg_wq_get_first"},
        {NULL, "accfg_wq_get_next"},
        {NULL, "accfg_wq_get_state"},
        {NULL, "accfg_wq_get_mode"},
        {NULL, "accfg_wq_get_id"},
        {NULL, "accfg_device_get_state"},
        {NULL, "accfg_unref"},
        {NULL, "accfg_device_get_gen_cap"},
        {NULL, "accfg_device_get_numa_node"},
        {NULL, "accfg_wq_get_priority"},
        {NULL, "accfg_wq_get_user_dev_path"},
        {NULL, "accfg_wq_get_devname"},
        {NULL, "accfg_device_get_version"},
        {NULL, "accfg_wq_get_block_on_fault"},
        // Terminate list/init
        {NULL, NULL}
};

typedef int                     (*accfg_new_ptr)(accfg_ctx **ctx);

typedef accfg_dev *             (*accfg_device_get_first_ptr)(accfg_ctx *ctx);

typedef const char *            (*accfg_device_get_devname_ptr)(accfg_dev *device);

typedef accfg_dev *             (*accfg_device_get_next_ptr)(accfg_dev *device);

typedef accfg_wq *              (*accfg_wq_get_first_ptr)(accfg_dev *device);

typedef accfg_wq *              (*accfg_wq_get_next_ptr)(accfg_wq *wq);

typedef enum accfg_wq_state     (*accfg_wq_get_state_ptr)(accfg_wq *wq);

typedef int                     (*accfg_wq_get_id_ptr)(accfg_wq *wq);

typedef enum accfg_device_state (*accfg_device_get_state_ptr)(accfg_dev *device);

typedef accfg_ctx *             (*accfg_unref_ptr)(accfg_ctx *ctx);

typedef enum accfg_wq_mode      (*accfg_wq_get_mode_ptr)(accfg_wq *wq);

typedef unsigned long           (*accfg_device_get_gen_cap_ptr)(accfg_dev *device);

typedef int                     (*accfg_wq_get_user_dev_path_ptr)(accfg_wq *wq, char *buf, size_t size);

typedef int                     (*accfg_device_get_numa_node_ptr)(accfg_dev *device);

typedef int                     (*accfg_wq_get_priority_ptr)(accfg_wq *wq);

typedef const char *            (*accfg_wq_get_devname_ptr)(accfg_wq *wq);

typedef unsigned int            (*accfg_device_get_version_ptr)(accfg_dev *device);

typedef int                     (*accfg_wq_get_block_on_fault_ptr)(accfg_wq *wq);

static const uint8_t  accelerator_name[]      = "iax";                         /**< Accelerator name */
static const uint32_t accelerator_name_length = sizeof(accelerator_name) - 2u; /**< Last symbol index */

static inline bool own_search_device_name(const uint8_t *src_ptr,
                                          const uint32_t name,
                                          const uint32_t name_size) noexcept {
    const uint8_t null_terminator = '\0';

    for (size_t symbol_idx = 0u; null_terminator != src_ptr[symbol_idx + name_size]; symbol_idx++) {
        const auto *candidate_ptr = reinterpret_cast<const uint32_t *>(src_ptr + symbol_idx);

        // Convert the first 3 bytes to lower case and make the 4th 0xff
        if (name == (*candidate_ptr | CHAR_MSK)) {
            return true;
        }
    }

    return false;
}

namespace qpl::ml::dispatcher {

hw_queue::hw_queue(hw_queue &&other) noexcept {
    priority_      = other.priority_;
    portal_mask_   = other.portal_mask_;
    portal_ptr_    = other.portal_ptr_;
    portal_offset_ = 0;

    other.portal_ptr_ = nullptr;
}

auto hw_queue::operator=(hw_queue &&other) noexcept -> hw_queue & {
    priority_      = other.priority_;
    portal_mask_   = other.portal_mask_;
    portal_ptr_    = other.portal_ptr_;
    portal_offset_ = 0;

    other.portal_ptr_ = nullptr;

    return *this;
}

hw_queue::~hw_queue() noexcept {
    // Freeing resources
    if (portal_ptr_ != nullptr) {
        munmap(portal_ptr_, 0x1000u);

        portal_ptr_ = nullptr;
    }
}

void hw_queue::set_portal_ptr(void *value_ptr) noexcept {
    portal_offset_ = reinterpret_cast<uint64_t>(value_ptr) & OWN_PAGE_MASK;
    portal_mask_   = reinterpret_cast<uint64_t>(value_ptr) & (~OWN_PAGE_MASK);
    portal_ptr_    = value_ptr;
}

auto hw_queue::get_portal_ptr() const noexcept -> void * {
    uint64_t offset = portal_offset_++;
    offset = (offset << 6) & OWN_PAGE_MASK;
    return reinterpret_cast<void *>(offset | portal_mask_);
}

auto hw_queue::enqueue_descriptor(void *desc_ptr) const noexcept -> qpl_status {
    uint8_t retry = 0u;

    void *current_place_ptr = get_portal_ptr();
    asm volatile("sfence\t\n"
                 ".byte 0xf2, 0x0f, 0x38, 0xf8, 0x02\t\n"
                 "setz %0\t\n"
    : "=r"(retry) : "a" (current_place_ptr), "d" (desc_ptr));

    return static_cast<qpl_status>(retry);
}

auto hw_queue::initialize_new_queue(void *wq_descriptor_ptr) noexcept -> hw_accelerator_status {

    auto *work_queue_ptr        = reinterpret_cast<accfg_wq *>(wq_descriptor_ptr);
    char path[64];
#ifdef LOG_HW_INIT
    auto work_queue_dev_name    = hw_work_queue_get_device_name(work_queue_ptr);
#endif

    if (ACCFG_WQ_ENABLED != hw_work_queue_get_state(work_queue_ptr)) {
        DIAG("     %7s: DISABLED\n", work_queue_dev_name);
        return HW_ACCELERATOR_WORK_QUEUES_NOT_AVAILABLE;
    }

    if (ACCFG_WQ_SHARED != hw_work_queue_get_mode(work_queue_ptr)) {
        DIAG("     %7s: UNSUPPOTED\n", work_queue_dev_name);
        return HW_ACCELERATOR_WORK_QUEUES_NOT_AVAILABLE;
    }

    DIAG("     %7s:\n", work_queue_dev_name);
    auto status = hw_work_queue_get_device_path(work_queue_ptr, path, 64 - 1);
    QPL_HWSTS_RET((0 > status), HW_ACCELERATOR_LIBACCEL_ERROR);

    DIAG("     %7s: opening descriptor %s", work_queue_dev_name, path);
    auto fd = open(path, O_RDWR);
    if(0 >= fd)
    {
        DIAGA(", access denied\n");
        return HW_ACCELERATOR_LIBACCEL_ERROR;
    }

    auto *region_ptr = mmap(nullptr, 0x1000u, PROT_WRITE, MAP_SHARED | MAP_POPULATE, fd, 0);
    close(fd);
    if(MAP_FAILED == region_ptr)
    {
        DIAGA(", limited MSI-X mapping failed\n");
        return HW_ACCELERATOR_LIBACCEL_ERROR;
    }
    DIAGA("\n");

    priority_       = hw_work_queue_get_priority(work_queue_ptr);
    block_on_fault_ = hw_work_queue_get_block_on_fault(work_queue_ptr);

#if 0
    DIAG("     %7s: size:        %d\n", work_queue_dev_name, accfg_wq_get_size(work_queue_ptr));
    DIAG("     %7s: threshold:   %d\n", work_queue_dev_name, accfg_wq_get_threshold(work_queue_ptr));
    DIAG("     %7s: priority:    %d\n", work_queue_dev_name, priority_);
    DIAG("     %7s: group:       %d\n", work_queue_dev_name, group_id);

    for(struct accfg_engine *engine = accfg_engine_get_first(device_ptr);
            engine != NULL; engine = accfg_engine_get_next(engine))
    {
        if(accfg_engine_get_group_id(engine) == group_id)
            DIAG("            %s\n", accfg_engine_get_devname(engine));
    }
#else
    DIAG("     %7s: priority:    %d\n", work_queue_dev_name, priority_);
    DIAG("     %7s: bof:         %d\n", work_queue_dev_name, block_on_fault_);
#endif

    hw_queue::set_portal_ptr(region_ptr);

    return HW_ACCELERATOR_STATUS_OK;
}

auto hw_queue::priority() const noexcept -> int32_t {
    return priority_;
}

auto hw_queue::get_block_on_fault() const noexcept -> bool {
    return block_on_fault_;
}

void hw_device::fill_hw_context(hw_accelerator_context *const hw_context_ptr) const noexcept {
    // Restore device properties
    hw_context_ptr->device_properties.max_set_size                  = hw_device::get_max_set_size();
    hw_context_ptr->device_properties.max_decompressed_set_size     = hw_device::get_max_decompressed_set_size();
    hw_context_ptr->device_properties.indexing_support_enabled      = hw_device::get_indexing_support_enabled();
    hw_context_ptr->device_properties.decompression_support_enabled = hw_device::get_decompression_support_enabled();
    hw_context_ptr->device_properties.max_transfer_size             = hw_device::get_max_transfer_size();
    hw_context_ptr->device_properties.cache_flush_available         = hw_device::get_cache_flush_available();
    hw_context_ptr->device_properties.cache_write_available         = hw_device::get_cache_write_available();
    hw_context_ptr->device_properties.overlapping_available         = hw_device::get_overlapping_available();
    hw_context_ptr->device_properties.block_on_fault_enabled        = hw_device::get_block_on_fault_available();
}

auto hw_device::enqueue_descriptor(void *desc_ptr) const noexcept -> bool {
    uint8_t retry = 0u;
    static thread_local std::uint32_t wq_idx = 0;

    // For small low-latency cases WQ with small transfer size may be preferable
    // TODO: order WQs by priority and engines capacity, check transfer sizes and other possible features
    for (uint64_t try_count = 0u; try_count < queue_count_; ++try_count) {
        hw_iaa_descriptor_set_block_on_fault((hw_descriptor *) desc_ptr, working_queues_[wq_idx].get_block_on_fault());

        retry = working_queues_[wq_idx].enqueue_descriptor(desc_ptr);
        wq_idx = (wq_idx+1) % queue_count_;
        if (!retry) {
            break;
        }
    }

    return static_cast<bool>(retry);
}

auto hw_device::get_max_set_size() const noexcept -> uint32_t {
    return GC_MAX_SET_SIZE(gen_cap_register_);
}

auto hw_device::get_max_decompressed_set_size() const noexcept -> uint32_t {
    return GC_MAX_DECOMP_SET_SIZE(gen_cap_register_);
}

auto hw_device::get_indexing_support_enabled() const noexcept -> uint32_t {
    return GC_IDX_SUPPORT(gen_cap_register_);
}

auto hw_device::get_decompression_support_enabled() const noexcept -> bool {
    return GC_DECOMP_SUPPORT(gen_cap_register_);
}

auto hw_device::get_max_transfer_size() const noexcept -> uint32_t {
    return GC_MAX_TRANSFER_SIZE(gen_cap_register_);
}

auto hw_device::get_cache_flush_available() const noexcept -> bool {
    return GC_CACHE_FLUSH(gen_cap_register_);
}

auto hw_device::get_cache_write_available() const noexcept -> bool {
    return GC_CACHE_WRITE(gen_cap_register_);
}

auto hw_device::get_overlapping_available() const noexcept -> bool {
    return GC_OVERLAPPING(gen_cap_register_);
}

auto hw_device::get_block_on_fault_available() const noexcept -> bool {
    return GC_BLOCK_ON_FAULT(gen_cap_register_);
}

auto hw_device::initialize_new_device(descriptor_t *device_descriptor_ptr) noexcept -> hw_accelerator_status {
    // Device initialization stage
    auto       *device_ptr          = reinterpret_cast<accfg_device *>(device_descriptor_ptr);
    const auto *name_ptr            = reinterpret_cast<const uint8_t *>(hw_device_get_name(device_ptr));
    const bool  is_iaa_device       = own_search_device_name(name_ptr, IAA_DEVICE, accelerator_name_length);

    version_major_ = hw_device_get_version(device_ptr)>>8u;
    version_minor_ = hw_device_get_version(device_ptr)&0xFF;

    cout << "%5s: " << name_ptr << endl;
    if (!is_iaa_device) {
        cout << "UNSUPPORTED: "<< name_ptr << endl;
        return HW_ACCELERATOR_WORK_QUEUES_NOT_AVAILABLE;
    }
    if (ACCFG_DEVICE_ENABLED != hw_device_get_state(device_ptr)) {
        cout << "DISABLED: " << name_ptr << endl;
        return HW_ACCELERATOR_WORK_QUEUES_NOT_AVAILABLE;
    }
    DIAGA("\n");

    gen_cap_register_ = hw_device_get_gen_cap_register(device_ptr);
    numa_node_id_     = hw_device_get_numa_node(device_ptr);

    cout << "version:" << version_major_ << version_minor_ << endl;
    cout << "numa: " << numa_node_id_;

    cout << " GENCAP: block on fault support:                      " <<  get_block_on_fault_available() << endl;
    cout << "GENCAP: overlapping copy support:                    " <<  get_overlapping_available() << endl;
    cout << "GENCAP: cache control support (memory):              " <<  get_cache_write_available() << endl;
    cout << "GENCAP: cache control support (cache flush):         " <<  get_cache_flush_available() << endl;
    cout << "GENCAP: maximum supported transfer size:   " <<  get_max_transfer_size() << endl;
    cout << "GENCAP: decompression support:                       " <<  get_decompression_support_enabled() << endl;
    cout << "GENCAP: indexing support:                            " <<  get_indexing_support_enabled() << endl;
    cout << "GENCAP: maximum decompression set size:              " <<  get_max_decompressed_set_size() << endl;
    cout << "GENCAP: maximum set size:                            " <<  get_max_set_size() << endl;

    // Working queues initialization stage
    auto *wq_ptr = hw_get_first_work_queue(device_ptr);
    auto wq_it   = working_queues_.begin();

    DIAG("%5s: getting device WQs\n", name_ptr);
    while (nullptr != wq_ptr) {
        if (HW_ACCELERATOR_STATUS_OK == wq_it->initialize_new_queue(wq_ptr)) {
            wq_it++;

            std::push_heap(working_queues_.begin(), wq_it,
                           [](const hw_queue &a, const hw_queue &b) -> bool {
                               return a.priority() < b.priority();
                           });
        }

        wq_ptr = hw_work_queue_get_next(wq_ptr);
    }

    // Check number of working queues
    queue_count_ = std::distance(working_queues_.begin(), wq_it);

    if (queue_count_ > 1) {
        auto begin = working_queues_.begin();
        auto end   = begin + queue_count_;

        std::sort_heap(begin, end, [](const hw_queue &a, const hw_queue &b) -> bool {
            return a.priority() < b.priority();
        });
    }

    if (queue_count_ == 0) {
        return HW_ACCELERATOR_WORK_QUEUES_NOT_AVAILABLE;
    }

    return HW_ACCELERATOR_STATUS_OK;
}

auto hw_device::size() const noexcept -> size_t {
    return queue_count_;
}

auto hw_device::numa_id() const noexcept -> uint64_t {
    return numa_node_id_;
}

auto hw_device::begin() const noexcept -> queues_container_t::const_iterator {
    return working_queues_.cbegin();
}

auto hw_device::end() const noexcept -> queues_container_t::const_iterator {
    return working_queues_.cbegin() + queue_count_;
}

}


hw_accelerator_status own_load_accelerator_configuration_driver(void **driver_instance_pptr) {

    cout << "loading driver: " << accelerator_configuration_driver_name << endl;
    // Try to load the accelerator configuration library
    void *driver_instance_ptr = dlopen(accelerator_configuration_driver_name, RTLD_LAZY);

    if (!driver_instance_ptr) {
        // This is needed for error handle. We need to call dlerror
        // for emptying error message. Otherwise we will receive error
        // message during loading symbols from another library
        dlerror();

        return HW_ACCELERATOR_LIBACCEL_NOT_FOUND;
    }

    *driver_instance_pptr = driver_instance_ptr;

    return HW_ACCELERATOR_STATUS_OK;
}


bool own_load_configuration_functions(void *driver_instance_ptr) {
    uint32_t i = 0u;

    cout <<"loading functions table:" << endl;
    while (functions_table[i].function_name) {
        cout << "    loading " << functions_table[i].function_name << endl;
        functions_table[i].function = (library_function) dlsym(driver_instance_ptr, functions_table[i].function_name);
        i++;

        char *err_message = dlerror();

        if (err_message) {
            return false;
        }
    }

    return true;
}

void hw_finalize_accelerator_driver(hw_driver_t *driver_ptr) {
    if (driver_ptr->driver_instance_ptr) {
        dlclose(driver_ptr->driver_instance_ptr);
    }

    driver_ptr->driver_instance_ptr = NULL;
}

hw_accelerator_status hw_initialize_accelerator_driver(hw_driver_t *driver_ptr) {

    // Variables
    driver_ptr->driver_instance_ptr = NULL;

    // Load DLL
    hw_accelerator_status status = own_load_accelerator_configuration_driver(&driver_ptr->driver_instance_ptr);

    if(status || driver_ptr->driver_instance_ptr == NULL) {
        hw_finalize_accelerator_driver(driver_ptr);

        return HW_ACCELERATOR_LIBACCEL_NOT_FOUND;
    }

    // If DLL is loaded successfully
    if (!own_load_configuration_functions(driver_ptr->driver_instance_ptr)) {
        hw_finalize_accelerator_driver(driver_ptr);

        return HW_ACCELERATOR_LIBACCEL_NOT_FOUND;
    }

    return HW_ACCELERATOR_STATUS_OK;
}


int32_t hw_driver_new_context(accfg_ctx **ctx) {
    return ((accfg_new_ptr) functions_table[0].function)(ctx);
}

accfg_dev *hw_context_get_first_device(accfg_ctx *ctx) {
    return ((accfg_device_get_first_ptr) functions_table[1].function)(ctx);
}

const char *hw_device_get_name(accfg_dev *device) {
    return ((accfg_device_get_devname_ptr) functions_table[2].function)(device);
}

accfg_dev *hw_device_get_next(accfg_dev *device) {
    return ((accfg_device_get_next_ptr) functions_table[3].function)(device);
}


accfg_wq *hw_get_first_work_queue(accfg_dev *device) {
    return ((accfg_wq_get_first_ptr) functions_table[4].function)(device);
}

accfg_wq *hw_work_queue_get_next(accfg_wq *wq) {
    return ((accfg_wq_get_next_ptr) functions_table[5].function)(wq);
}

enum accfg_wq_state hw_work_queue_get_state(accfg_wq *wq) {
    return ((accfg_wq_get_state_ptr) functions_table[6].function)(wq);
}

enum accfg_wq_mode hw_work_queue_get_mode(accfg_wq *wq) {
    return ((accfg_wq_get_mode_ptr) functions_table[7].function)(wq);
}

int32_t hw_work_queue_get_id(accfg_wq *wq) {
    return ((accfg_wq_get_id_ptr) functions_table[8].function)(wq);
}

enum accfg_device_state hw_device_get_state(accfg_dev *device) {
    return ((accfg_device_get_state_ptr) functions_table[9].function)(device);
}

accfg_ctx *hw_context_close(accfg_ctx *ctx) {
    return ((accfg_unref_ptr) functions_table[10].function)(ctx);
}

uint64_t hw_device_get_gen_cap_register(accfg_dev *device) {
    return ((accfg_device_get_gen_cap_ptr) functions_table[11].function)(device);
}

uint64_t hw_device_get_numa_node(accfg_dev *device) {
    return ((accfg_device_get_numa_node_ptr) functions_table[12].function)(device);
}

int32_t hw_work_queue_get_priority(accfg_wq *wq) {
    return ((accfg_wq_get_priority_ptr) functions_table[13].function)(wq);
}

int hw_work_queue_get_device_path(accfg_wq *wq, char *buf, size_t size) {
    return ((accfg_wq_get_user_dev_path_ptr) functions_table[14].function)(wq, buf, size);
}

const char * hw_work_queue_get_device_name(accfg_wq *wq) {
    return ((accfg_wq_get_devname_ptr) functions_table[15].function)(wq);
}

unsigned int hw_device_get_version(accfg_dev *device) {
    return ((accfg_device_get_version_ptr) functions_table[16].function)(device);
}

int hw_work_queue_get_block_on_fault(accfg_wq *wq) {
    return ((accfg_wq_get_block_on_fault_ptr) functions_table[17].function)(wq);
}


int main() {
	hw_driver_t        hw_driver_{};
	hw_accelerator_status status = hw_initialize_accelerator_driver(&hw_driver_);
	cout << "hw_initialize_accelerator_driver status: " << status << endl;
	if (status != HW_ACCELERATOR_STATUS_OK) {return 1;}
	cout << "creating context" << endl;
	accfg_ctx *ctx_ptr = nullptr;
	int32_t context_creation_status = hw_driver_new_context(&ctx_ptr);
	cout << "context_creation_status:" << context_creation_status << endl;

	cout << "enumerating devices" << endl;
	auto *dev_tmp_ptr = hw_context_get_first_device(ctx_ptr);
	if (nullptr == dev_tmp_ptr) {
	    cout << "hw_context_get_first_device nullptr";
	}

    static constexpr uint32_t max_devices = MAX_NUM_DEV;
    using device_container_t = std::array<qpl::ml::dispatcher::hw_device, max_devices>;
    device_container_t devices_{};
    auto device_it    = devices_.begin();
    while (nullptr != dev_tmp_ptr) {
        if (HW_ACCELERATOR_STATUS_OK == device_it->initialize_new_device(dev_tmp_ptr)) {
            device_it++;
        }

        // Retrieve the "next" device in the system based on given device
        dev_tmp_ptr = hw_device_get_next(dev_tmp_ptr);
    }
    uint32_t device_count_ = std::distance(devices_.begin(), device_it);
    cout << "device count: " << device_count_;

}