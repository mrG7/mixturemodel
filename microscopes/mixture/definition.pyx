from microscopes.models import model_descriptor

cdef vector[shared_ptr[c_component_model]] get_cmodels(models):
    cdef vector[shared_ptr[c_component_model]] c_models
    for m in models:
        c_models.push_back((<_base>m._c_descriptor).get())
    return c_models

def _validate(models):
    for m in models:
        if not isinstance(m, model_descriptor):
            raise ValueError("invalid model given: {}".format(repr(m)))

cdef class fixed_model_definition:
    def __cinit__(self, int groups, models):
        _validate(models)
        self._thisptr.reset(
            new c_fixed_model_definition(groups, get_cmodels(models)))
        assert self._thisptr.get().nmodels() == len(models)
        self._groups = groups
        self._models = list(models)

cdef class model_definition:
    def __cinit__(self, models):
        _validate(models)
        self._thisptr.reset(new c_model_definition(get_cmodels(models)))
        assert self._thisptr.get().nmodels() == len(models)
        self._models = list(models)