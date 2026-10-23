#pragma once

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/dictionary.hpp>

namespace godot {

class VoxEnNativeBuilder : public RefCounted {
    GDCLASS(VoxEnNativeBuilder, RefCounted)

    Dictionary result;

protected:
    static void _bind_methods();

public:
    Dictionary build_mesh_data(const Dictionary &job_data);
    void set_result(const Dictionary &value);
    Dictionary get_result() const;
};

} // namespace godot
