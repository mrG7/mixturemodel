# cython: embedsignature=True


# python imports
import numpy as np
import numpy.ma as ma
import copy

from microscopes.common._rng import rng
from microscopes.common._entity_state import entity_based_state_object
from microscopes.common.recarray._dataview cimport abstract_dataview
from microscopes.io.schema_pb2 import CRP
from distributions.io.schema_pb2 import DirichletDiscrete
from microscopes.common import validator


cdef numpy_dataview get_dataview_for(y):
    """
    creates a dataview for a single recarray

    not very efficient
    """

    cdef np.ndarray inp_data
    cdef np.ndarray inp_mask

    if hasattr(y, 'mask'):
        # deal with the mask
        inp_mask = np.ascontiguousarray(y.mask)
    else:
        inp_mask = None

    # this allows us to unify the two possible representations here
    # notice:
    # In [53]: y
    # Out[53]:
    # masked_array(data = [(--, 10.0)],
    #              mask = [(True, False)],
    #        fill_value = (True, 1e+20),
    #             dtype = [('f0', '?'), ('f1', '<f8')])
    #
    # In [54]: np.ascontiguousarray(y)
    # Out[54]:
    # array([(True, 10.0)],
    #       dtype=[('f0', '?'), ('f1', '<f8')])
    #
    # In [57]: np.ascontiguousarray(y[0])
    # Out[57]:
    # array([(True, 10.0)],
    #       dtype=[('f0', '?'), ('f1', '<f8')])

    inp_data = np.ascontiguousarray(y)
    if inp_mask is not None:
        inp_data = ma.array(inp_data, mask=inp_mask)

    return numpy_dataview(inp_data)


cdef class state:
    """The underlying state of a Dirichlet Process mixture model.

    You should not explicitly construct a state object.
    Instead, use `initialize`.
    """
    def __cinit__(self, model_definition defn, **kwargs):
        self._defn = defn
        cdef vector[hyperparam_bag_t] c_feature_hps_bytes
        cdef vector[size_t] c_assignment

        # note: python cannot overload __cinit__(), so we
        # use kwargs to handle both the random initialization case and
        # the deserialize from string case
        if not (('data' in kwargs) ^ ('bytes' in kwargs)):
            raise ValueError("need exaclty one of `data' or `bytes'")

        valid_kwargs = ('data', 'bytes', 'r',
                        'cluster_hp', 'feature_hps', 'assignment',)
        validator.validate_kwargs(kwargs, valid_kwargs)

        if 'data' in kwargs:
            # handle the random initialization case
            self._validate_kwargs(kwargs)
            cluster_hp_bytes = self._get_cluster_hp_bytes(kwargs)
            c_feature_hps_bytes = self._get_feature_hp_bytes(kwargs)
            c_assignment = self._get_assignment(kwargs)

            self._thisptr = c_initialize(
                defn._thisptr.get()[0],
                cluster_hp_bytes,
                c_feature_hps_bytes,
                c_assignment,
                (<abstract_dataview> kwargs['data'])._thisptr.get()[0],
                (<rng> kwargs['r']  )._thisptr[0])
        else:
            # handle the deserialize case
            self._thisptr = c_deserialize(
                defn._thisptr.get()[0],
                kwargs['bytes'])

        if self._thisptr.get() == NULL:
            raise RuntimeError("could not properly construct state")

    def _validate_kwargs(self, kwargs):
        validator.validate_type(kwargs['data'], abstract_dataview, "data")
        validator.validate_len(kwargs['data'], self._defn.n(), "data")

        if 'r' not in kwargs:
            raise ValueError("need parameter `r'")
        validator.validate_type(kwargs['r'], rng, "r")

    def _get_cluster_hp_bytes(self, kwargs):
        cluster_hp = kwargs.get('cluster_hp', None)
        if cluster_hp is None:
            cluster_hp = {'alpha': 1.}
        validator.validate_type(cluster_hp, dict, "cluster_hp")

        m = CRP()
        m.alpha = cluster_hp['alpha']
        return m.SerializeToString()

    def _get_feature_hp_bytes(self, kwargs):
        cdef vector[hyperparam_bag_t] c_feature_hps_bytes
        feature_hps = kwargs.get('feature_hps', None)
        if feature_hps is None:
            feature_hps = [m.default_hyperparams() for m in self._defn.models()]
        validator.validate_len(
            feature_hps, len(self._defn.models()), "feature_hps")
        feature_hps_bytes = [
            m.py_desc().shared_dict_to_bytes(hp)
            for hp, m in zip(feature_hps, self._defn.models())]
        for s in feature_hps_bytes:
            c_feature_hps_bytes.push_back(s)
        return c_feature_hps_bytes

    def _get_assignment(self, kwargs):
        cdef vector[size_t] c_assignment
        assignment = kwargs.get('assignment', None)
        if assignment is not None:
            validator.validate_len(assignment, kwargs['data'].size(), "assignment")
            for s in assignment:
                validator.validate_nonnegative(s)
                c_assignment.push_back(s)
        return c_assignment

    # XXX: get rid of these introspection methods in the future
    def get_feature_types(self):
        models = self._defn.models()
        types = [m.py_desc()._model_module for m in models]
        return types

    def get_feature_dtypes(self):
        models = self._defn.models()
        dtypes = [('', m.py_desc().get_np_dtype()) for m in models]
        return np.dtype(dtypes)

    def get_cluster_hp(self):
        m = CRP()
        raw = str(self._thisptr.get().get_cluster_hp())
        m.ParseFromString(raw)
        return {'alpha': m.alpha}

    def set_cluster_hp(self, dict raw):
        m = CRP()
        m.alpha = float(raw['alpha'])
        self._thisptr.get().set_cluster_hp(m.SerializeToString())

    def _validate_eid(self, eid):
        validator.validate_in_range(eid, self.nentities())

    def _validate_fid(self, fid):
        validator.validate_in_range(fid, self.nfeatures())

    def _validate_gid(self, gid):
        if not self._thisptr.get().isactivegroup(gid):
            raise ValueError("invalid gid: {}".format(gid))

    def get_feature_hp(self, int i):
        self._validate_fid(i)
        raw = str(self._thisptr.get().get_feature_hp(i))
        models = self._defn.models()
        return models[i].py_desc().shared_bytes_to_dict(raw)

    def set_feature_hp(self, int i, dict d):
        self._validate_fid(i)
        models = self._defn.models()
        cdef hyperparam_bag_t raw = models[i].py_desc().shared_dict_to_bytes(d)
        self._thisptr.get().set_feature_hp(i, raw)

    def get_suffstats(self, int gid, int fid):
        self._validate_fid(fid)
        self._validate_gid(gid)
        models = self._defn.models()
        raw = str(self._thisptr.get().get_suffstats(gid, fid))
        return models[fid].py_desc().group_bytes_to_dict(raw)

    def set_suffstats(self, int gid, int fid, dict d):
        self._validate_fid(fid)
        self._validate_gid(gid)
        models = self._defn.models()
        cdef suffstats_bag_t raw = (
            models[fid].py_desc().shared_dict_to_bytes(d)
        )
        self._thisptr.get().set_suffstats(gid, fid, raw)

    def assignments(self):
        return list(self._thisptr.get().assignments())

    def empty_groups(self):
        return list(self._thisptr.get().empty_groups())

    def ngroups(self):
        return self._thisptr.get().ngroups()

    def nentities(self):
        return self._thisptr.get().nentities()

    def nfeatures(self):
        return len(self._defn.models())

    def groupsize(self, int gid):
        self._validate_gid(gid)
        return self._thisptr.get().groupsize(gid)

    def is_group_empty(self, int gid):
        self._validate_gid(gid)
        return not self._groups.nentities_in_group(gid)

    def groups(self):
        cdef list g = self._thisptr.get().groups()
        return g

    def create_group(self, rng r):
        assert r
        return self._thisptr.get().create_group(r._thisptr[0])

    def delete_group(self, int gid):
        self._validate_gid(gid)
        self._thisptr.get().delete_group(gid)

    def add_value(self, int gid, int eid, y, rng r):
        self._validate_gid(gid)
        self._validate_eid(eid)
        # XXX: need to validate y
        validator.validate_not_none(r)

        cdef numpy_dataview view = get_dataview_for(y)
        cdef row_accessor acc = view._thisptr.get().get()
        self._thisptr.get().add_value(gid, eid, acc, r._thisptr[0])

    def remove_value(self, int eid, y, rng r):
        self._validate_eid(eid)
        # XXX: need to validate y
        validator.validate_not_none(r)

        cdef numpy_dataview view = get_dataview_for(y)
        cdef row_accessor acc = view._thisptr.get().get()
        return self._thisptr.get().remove_value(eid, acc, r._thisptr[0])

    def score_value(self, y, rng r):
        # XXX: need to validate y
        validator.validate_not_none(r)

        cdef numpy_dataview view = get_dataview_for(y)
        cdef row_accessor acc = view._thisptr.get().get()
        cdef pair[vector[size_t], vector[float]] ret = (
            self._thisptr.get().score_value(acc, r._thisptr[0])
        )
        ret0 = list(ret.first)
        ret1 = np.array(list(ret.second))
        return ret0, ret1

    def score_data(self, features, groups, rng r):
        validator.validate_not_none(r)
        if features is None:
            features = range(len(self._defn.models()))
        elif not hasattr(features, '__iter__'):
            features = [features]

        if groups is None:
            groups = self.groups()
        elif not hasattr(groups, '__iter__'):
            groups = [groups]

        cdef vector[size_t] f
        for i in features:
            self._validate_fid(i)
            f.push_back(i)

        cdef vector[size_t] g
        for i in groups:
            self._validate_gid(i)
            g.push_back(i)

        return self._thisptr.get().score_data(f, g, r._thisptr[0])

    def sample_post_pred(self, y_new, rng r):
        # XXX: need to validate y
        validator.validate_not_none(r)
        if y_new is None:
            D = self.nfeatures()
            y_new = ma.masked_array(
                np.array([tuple(0 for _ in xrange(D))], dtype=[('', int)] * D),
                mask=[tuple(True for _ in xrange(D))])

        cdef numpy_dataview view = get_dataview_for(y_new)
        cdef row_accessor acc = view._thisptr.get().get()

        # ensure the state has 1 empty group
        self._thisptr.get().ensure_k_empty_groups(1, False, r._thisptr[0])

        cdef vector[runtime_type] out_ctypes = \
            self._defn._thisptr.get().get_runtime_types()
        out_dtype = [('', get_np_type(t)) for t in out_ctypes]

        # build an appropriate numpy array to store the output
        cdef np.ndarray out_npd = np.zeros(1, dtype=out_dtype)

        cdef row_mutator mut = (
            row_mutator(<uint8_t *> out_npd.data, &out_ctypes)
        )
        gid = self._thisptr.get().sample_post_pred(acc, mut, r._thisptr[0])

        return gid, out_npd

    def score_assignment(self):
        return self._thisptr.get().score_assignment()

    def score_joint(self, rng r):
        validator.validate_not_none(r)
        return self._thisptr.get().score_joint(r._thisptr[0])

    def dcheck_consistency(self):
        self._thisptr.get().dcheck_consistency()

    def serialize(self):
        return self._thisptr.get().serialize()

    def __reduce__(self):
        return (_reconstruct_state, (self._defn, self.serialize()))

    def __copy__(self):
        """Returns a shallow copy of this object

        Shallow copy current means the model object is shared,
        but the underlying state representation is not
        """
        return state(self._defn, bytes=self.serialize())

    def __deepcopy__(self, memo):
        defn = copy.deepcopy(self._defn, memo)
        return state(defn, bytes=self.serialize())


def bind(state s, abstract_dataview data):
    cdef shared_ptr[c_entity_based_state_object] px
    px.reset(new c_model(s._thisptr, data._thisptr))
    cdef entity_based_state_object ret = (
        entity_based_state_object(s._defn.models())
    )
    ret._thisptr = px
    ret._refs = data
    return ret


def initialize(model_definition defn,
               abstract_dataview data,
               rng r,
               **kwargs):
    """Initialize state to a random, valid point in the state space

    Parameters
    ----------
    defn : model definition
    data : recarray dataview
    rng : random state

    """
    return state(defn=defn, data=data, r=r, **kwargs)


def deserialize(model_definition defn, bytes):
    """Restore a state object from a bytestring representation.

    Note that a serialized representation of a state object does
    not contain its own structural definition.

    Parameters
    ----------
    defn : model definition
    bytes : bytestring representation

    """
    return state(defn=defn, bytes=bytes)


def _reconstruct_state(defn, bytes):
    return deserialize(defn, bytes)
