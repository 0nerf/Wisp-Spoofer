<script setup lang="ts">
withDefaults(defineProps<{ size?: number }>(), {
  size: 48,
})
</script>

<template>
  <img 
    src="/wisp-logo.png" 
    :width="size" 
    :height="size" 
    class="object-cover" 
    alt="Wisp Logo" 
  />
</template>
