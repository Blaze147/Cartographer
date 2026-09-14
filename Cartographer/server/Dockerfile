# Build stage
FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src
COPY Cartographer.csproj .
RUN dotnet restore
COPY . .
RUN dotnet publish -c Release -o /out

# Runtime stage
FROM mcr.microsoft.com/dotnet/aspnet:8.0
WORKDIR /app
COPY --from=build /out .
ENV ASPNETCORE_URLS=http://+:8080 \
    CARTOGRAPHER_DATA=/data/data.json
# removing due to a limitation with Railway
# VOLUME /data
EXPOSE 8080
ENTRYPOINT ["dotnet", "Cartographer.dll"]
