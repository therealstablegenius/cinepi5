/*
* gpio_tally.c - Production-grade GPIO tally driver for CinePi5
*
* Features:
* - Complete Device Tree support with YAML binding
* - Configurable initial state (module param + DT property)
* - Rate-limited error logging
* - Input validation and clamping
* - Comprehensive documentation
*/

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/init.h>
#include <linux/gpio/consumer.h>
#include <linux/platform_device.h>
#include <linux/property.h>
#include <linux/sysfs.h>
#include <linux/fs.h>
#include <linux/device.h>
#include <linux/cdev.h>
#include <linux/uaccess.h>
#include <linux/err.h>
#include <linux/slab.h>
#include <linux/mutex.h>
#include <linux/of.h>
#include <linux/ratelimit.h>

#define DRIVER_NAME "gpio-tally"
#define MAX_TALLY_NAME_LEN 32
#define DEFAULT_INIT_STATE 0

MODULE_LICENSE("GPL v2");
MODULE_AUTHOR("CineSoft Labs");
MODULE_DESCRIPTION("GPIO tally light driver for CinePi5");
MODULE_VERSION("2.4");

static int initial_state = DEFAULT_INIT_STATE;
module_param(initial_state, int, 0644);
MODULE_PARM_DESC(initial_state, "Initial state (0=off, 1=on, default=0)");

struct gpio_tally_data {
struct gpio_desc *tally_gpiod;
struct device *dev;
struct cdev cdev;
dev_t devno;
bool led_state;
struct mutex lock;
char name[MAX_TALLY_NAME_LEN];
int id;
};

static struct class *tally_class;
static DEFINE_IDA(tally_ida);

/* Sysfs interface with validation */
static ssize_t state_show(struct device *dev,
struct device_attribute *attr, char *buf)
{
struct gpio_tally_data *data = dev_get_drvdata(dev);
int state;

mutex_lock(&data->lock);
state = data->led_state;
mutex_unlock(&data->lock);

return sprintf(buf, "%d\n", state);
}

static ssize_t state_store(struct device *dev,
struct device_attribute *attr,
const char *buf, size_t count)
{
struct gpio_tally_data *data = dev_get_drvdata(dev);
unsigned long val;
int ret;

ret = kstrtoul(buf, 10, &val);
if (ret) {
if (printk_ratelimit())
dev_err(dev, "Invalid state value: %s\n", buf);
return ret;
}

/* Clamp to 0/1 */
val = !!val;

mutex_lock(&data->lock);
data->led_state = val;
gpiod_set_value_cansleep(data->tally_gpiod, data->led_state);
mutex_unlock(&data->lock);

return count;
}
static DEVICE_ATTR_RW(state);

/* Character device operations */
static int tally_open(struct inode *inode, struct file *filp)
{
filp->private_data = container_of(inode->i_cdev, struct gpio_tally_data, cdev);
return 0;
}

static ssize_t tally_read(struct file *filp, char __user *buf,
size_t count, loff_t *f_pos)
{
struct gpio_tally_data *data = filp->private_data;
char state[2];

mutex_lock(&data->lock);
state[0] = '0' + data->led_state;
state[1] = '\n';
mutex_unlock(&data->lock);

return simple_read_from_buffer(buf, count, f_pos, state, 2);
}

static ssize_t tally_write(struct file *filp, const char __user *buf,
size_t count, loff_t *f_pos)
{
struct gpio_tally_data *data = filp->private_data;
char val;

if (get_user(val, buf))
return -EFAULT;

mutex_lock(&data->lock);
switch (val) {
case '0':
data->led_state = false;
break;
case '1':
data->led_state = true;
break;
default:
mutex_unlock(&data->lock);
if (printk_ratelimit())
dev_err(data->dev, "Invalid input: 0x%02x\n", val);
return -EINVAL;
}

gpiod_set_value_cansleep(data->tally_gpiod, data->led_state);
mutex_unlock(&data->lock);

return 1;
}

static const struct file_operations tally_fops = {
.owner = THIS_MODULE,
.open = tally_open,
.read = tally_read,
.write = tally_write,
};

static int gpio_tally_probe(struct platform_device *pdev)
{
struct device *dev = &pdev->dev;
struct gpio_tally_data *data;
bool dt_initial_state = initial_state;
int ret;

/* Parse DT properties */
if (device_property_read_bool(dev, "initial-on")) {
dt_initial_state = true;
dev_info(dev, "DT overrides initial state to ON\n");
}

data = devm_kzalloc(dev, sizeof(*data), GFP_KERNEL);
if (!data)
return -ENOMEM;

mutex_init(&data->lock);
platform_set_drvdata(pdev, data);

data->id = ida_alloc(&tally_ida, GFP_KERNEL);
if (data->id < 0)
return data->id;

snprintf(data->name, MAX_TALLY_NAME_LEN, "%s%d", DRIVER_NAME, data->id);

data->tally_gpiod = devm_gpiod_get(dev, "tally", GPIOD_OUT_LOW);
if (IS_ERR(data->tally_gpiod))
return dev_err_probe(dev, PTR_ERR(data->tally_gpiod),
"Failed to get tally GPIO\n");

data->led_state = dt_initial_state;
gpiod_direction_output(data->tally_gpiod, data->led_state);

ret = alloc_chrdev_region(&data->devno, 0, 1, data->name);
if (ret)
goto err_free_ida;

cdev_init(&data->cdev, &tally_fops);
data->cdev.owner = THIS_MODULE;

ret = cdev_add(&data->cdev, data->devno, 1);
if (ret)
goto err_unregister_chrdev;

data->dev = device_create(tally_class, dev, data->devno, data, data->name);
if (IS_ERR(data->dev)) {
ret = PTR_ERR(data->dev);
goto err_cdev_del;
}

ret = device_create_file(data->dev, &dev_attr_state);
if (ret)
goto err_device_destroy;

dev_info(dev, "Registered %s (initial state: %d)\n",
data->name, data->led_state);
return 0;

err_device_destroy:
device_destroy(tally_class, data->devno);
err_cdev_del:
cdev_del(&data->cdev);
err_unregister_chrdev:
unregister_chrdev_region(data->devno, 1);
err_free_ida:
ida_free(&tally_ida, data->id);
return ret;
}

static int gpio_tally_remove(struct platform_device *pdev)
{
struct gpio_tally_data *data = platform_get_drvdata(pdev);

device_remove_file(data->dev, &dev_attr_state);
device_destroy(tally_class, data->devno);
cdev_del(&data->cdev);
unregister_chrdev_region(data->devno, 1);
mutex_destroy(&data->lock);
ida_free(&tally_ida, data->id);

dev_info(&pdev->dev, "Unregistered %s\n", data->name);
return 0;
}

static const struct of_device_id gpio_tally_of_match[] = {
{ .compatible = "cinesoft,gpio-tally", },
{ }
};
MODULE_DEVICE_TABLE(of, gpio_tally_of_match);

static struct platform_driver gpio_tally_driver = {
.driver = {
.name = DRIVER_NAME,
.of_match_table = gpio_tally_of_match,
},
.probe = gpio_tally_probe,
.remove = gpio_tally_remove,
};

static int __init gpio_tally_init(void)
{
int ret;

tally_class = class_create(THIS_MODULE, DRIVER_NAME);
if (IS_ERR(tally_class))
return PTR_ERR(tally_class);

ret = platform_driver_register(&gpio_tally_driver);
if (ret)
class_destroy(tally_class);

pr_info("Loaded (v%s), default init state: %d\n",
MODULE_VERSION, initial_state);
return ret;
}

static void __exit gpio_tally_exit(void)
{
platform_driver_unregister(&gpio_tally_driver);
class_destroy(tally_class);
ida_destroy(&tally_ida);
pr_info("Unloaded\n");
}

module_init(gpio_tally_init);
module_exit(gpio_tally_exit);