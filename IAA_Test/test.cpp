#include <fcntl.h>
#include <sys/mman.h>
#include <dlfcn.h>
#include <iostream>
#include <hw_devices.h>
#include <hw_status.h>
using namespace std;

typedef void *library_function;

typedef struct {
    library_function function;          /**< Function address */
    const char       *function_name;    /**< Function name */
} qpl_desc_t;


static const char *accelerator_configuration_driver_name = "libaccel-config.so.1";
#define RTLD_LAZY	0x00001	/* Lazy function call binding.  */

typedef int                     (*accfg_new_ptr)(accfg_ctx **ctx);
typedef accfg_dev *             (*accfg_device_get_first_ptr)(accfg_ctx *ctx);


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
/*
	void * ptr = nullptr;
	hw_accelerator_status status = own_load_accelerator_configuration_driver(&ptr);
	cout << "setaeat" << status << endl;
	bool result = own_load_configuration_functions(ptr);
	cout << "configureation result: " << result << endl;
	*/
}
