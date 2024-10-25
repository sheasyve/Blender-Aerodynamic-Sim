# grid.pyx
# cython: language_level=3

import numpy as np
cimport numpy as cnp
from mathutils import Vector

cdef class MACGrid:

    def __init__(self, tuple grid_size, double cell_size):
        cdef cnp.npy_intp x, y, z
        self.grid_size = grid_size
        self.cell_size = cell_size
        cdef cnp.npy_intp nx = self.grid_size[0]
        cdef cnp.npy_intp ny = self.grid_size[1]
        cdef cnp.npy_intp nz = self.grid_size[2]
        self.u = np.zeros((nx+1, ny, nz), dtype=np.float64)
        self.v = np.zeros((nx, ny+1, nz), dtype=np.float64)
        self.w = np.zeros((nx, ny, nz+1), dtype=np.float64)
        self.pressure = np.zeros((nx, ny, nz), dtype=np.float64)
        self.density = np.zeros((nx, ny, nz), dtype=np.float64)
        self.position = np.zeros((nx, ny, nz, 3), dtype=np.float64)
        for x in range(nx):
            for y in range(ny):
                for z in range(nz):
                    self.position[x, y, z, :] = [(x + 0.5) * cell_size, (y + 0.5) * cell_size, (z + 0.5) * cell_size]  # Mac grid offset

    cpdef cnp.ndarray get_cell_position(self, cnp.npy_intp x, cnp.npy_intp y, cnp.npy_intp z):
        return self.position[x, y, z, :]

    cpdef void set_face_velocities(self, cnp.npy_intp x, cnp.npy_intp y, cnp.npy_intp z, cnp.ndarray vel):
        cdef cnp.npy_intp nx = self.grid_size[0]
        cdef cnp.npy_intp ny = self.grid_size[1]
        cdef cnp.npy_intp nz = self.grid_size[2]
        if 0 <= x < nx + 1:
            self.u[x, y, z] = vel[0]
        if 0 <= x - 1 < nx + 1:
            self.u[x - 1, y, z] = vel[0]
        if 0 <= y < ny + 1:
            self.v[x, y, z] = vel[1]
        if 0 <= y - 1 < ny + 1:
            self.v[x, y - 1, z] = vel[1]
        if 0 <= z < nz + 1:
            self.w[x, y, z] = vel[2]
        if 0 <= z - 1 < nz + 1:
            self.w[x, y, z - 1] = vel[2]

    cpdef void update_particle_positions(self, object particle_objects, int frame):
        positions = self.position.reshape(-1, 3)
        for i, particle in enumerate(particle_objects):
            if i < positions.shape[0]:
                particle.location = Vector(positions[i])
                particle.keyframe_insert(data_path="location", frame=frame)
