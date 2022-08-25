# until

*Keep track of important milestones in the terminal.*

## Buildling

```
git clone https://github.com/kdchambers/until
cd until
zig build run
```

Until has no build dependencies.

## Usage
### Add a new event

```
until add <event_description> <date>
until add "Trip to New York" 22/01/2023 
```

### List events

```
until list
> 1. 58 days until Trip to New York
```

### Reset saved data

```
until reset
```