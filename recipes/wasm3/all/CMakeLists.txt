cmake_minimum_required(VERSION 3.21)
project(wasm3 C)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED YES)
set(CMAKE_C_EXTENSIONS YES)

add_subdirectory(src/source)

file(GLOB M3_HEADERS src/source/*.h)
install(TARGETS m3 ARCHIVE DESTINATION lib)
install(FILES ${M3_HEADERS} DESTINATION include)
