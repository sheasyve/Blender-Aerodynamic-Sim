# grid.pxd
cimport numpy as cnp
from mathutils import Vector

cdef class MACGrid:
    cdef cnp.npy_intp grid_size[3]
    cdef double cell_size
    cdef cnp.ndarray u       # x-vel (ux) at faces (array sz: nx+1, ny, nz)
    cdef cnp.ndarray v       # y-vel (uy) at faces (array sz: nx, ny+1, nz)
    cdef cnp.ndarray w       # z-vel (uz) at faces (array sz: nx, ny, nz+1)
    cdef cnp.ndarray pressure    # pressure (p) at cell center (array sz: nx, ny, nz)
    cdef cnp.ndarray density     # density (rho) at cell center (array sz, ny, nz)
    cdef cnp.ndarray position    # positions (pos) of cell center (array sz: nx, ny, nz, 3)

    cpdef cnp.ndarray get_cell_position(self, cnp.npy_intp x, cnp.npy_intp y, cnp.npy_intp z)
    cpdef void update_particle_positions(self, object particle_objects, int frame)

'''Therefore, for a grid of nx, ny, nz cells, we store the pressure in a
nx, ny, nz array, the x component of the velocity in a nx+1, ny, nz
array, the y component of the velocity in a nx, ny + 1, nz array, and
the z component of the velocity in a nx, ny, nz + 1 array.
(Fluid Simulation For Computer Graphics: A Tutorial in Grid Based and Particle
Based Methods)'''